import Foundation

public struct BlindCandidate: Sendable, Hashable {
    public let label: String
    public let agentRunID: UUID
    public let response: String
}

public struct JudgeEngine: Sendable {
    private let adapters: [HarnessKind: any HarnessAdapter]
    private let evidence: EvidenceStore?
    private let maxConcurrentJudges: Int
    public init(adapters: [any HarnessAdapter], evidence: EvidenceStore? = nil, maxConcurrentJudges: Int = 3) { self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) }); self.evidence = evidence; self.maxConcurrentJudges = max(1, maxConcurrentJudges) }

    public static func blindCandidates(for run: BenchmarkRun) -> [BlindCandidate] {
        let ordered = run.agents.sorted { ($0.blindReviewOrder ?? $0.displayOrder) < ($1.blindReviewOrder ?? $1.displayOrder) }
        return ordered.enumerated().compactMap { index, agent in
            guard agent.state == .completed, let attempt = agent.attempts.last else { return nil }
            guard !attempt.finalResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(label: Self.label(index), agentRunID: agent.id, response: attempt.finalResponse)
        }
    }

    public func judge(run: BenchmarkRun) async -> [JudgeVote] {
        let candidates = Self.blindCandidates(for: run)
        guard candidates.count >= 2 else {
            return run.judgeConfigurations.map { .init(runID: run.id, judge: $0, errorMessage: "At least two completed candidates with responses are required.") }
        }
        return await withTaskGroup(of: (Int, JudgeVote).self, returning: [JudgeVote].self) { group in
            var next = 0
            for _ in 0..<min(maxConcurrentJudges, run.judgeConfigurations.count) {
                let index = next; next += 1
                group.addTask { (index, await self.runJudge(run.judgeConfigurations[index], run: run, candidates: candidates)) }
            }
            var votes = [(Int, JudgeVote)]()
            while let vote = await group.next() {
                votes.append(vote)
                if Task.isCancelled { group.cancelAll(); break }
                if next < run.judgeConfigurations.count {
                    let index = next; next += 1
                    group.addTask { (index, await self.runJudge(run.judgeConfigurations[index], run: run, candidates: candidates)) }
                }
            }
            return votes.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func judgeAndPersist(run: BenchmarkRun, history: SQLiteHistoryStore) async throws -> BenchmarkRun {
        var updated = run
        updated.judgeVotes = await judge(run: run)
        guard !Task.isCancelled else { return run }
        try await history.saveRun(updated)
        return updated
    }

    private func runJudge(_ judge: JudgeConfiguration, run: BenchmarkRun, candidates: [BlindCandidate]) async -> JudgeVote {
        let attemptID = UUID()
        guard let adapter = adapters[judge.harness] else { return .init(id: attemptID, runID: run.id, judge: judge, errorMessage: "No adapter is configured for \(judge.harness.rawValue).") }
        let packet = candidates.map { "Candidate \($0.label):\n\($0.response)" }.joined(separator: "\n\n")
        let steering = judge.steeringPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (steering?.isEmpty == false ? "Judge instructions:\n\(steering!)\n\n" : "") + "You are an impartial judge. Compare the blind candidate responses below. Return only strict JSON with this shape: {\"winner\":\"A\",\"reason\":\"concise reason\"}. The winner must be one of the candidate labels.\n\nBLIND CANDIDATES\n" + packet
        let request = HarnessRequest(runID: run.id, attemptID: attemptID, prompt: prompt, directoryPath: run.directoryPath, executionMode: .readOnly, configuration: .init(harness: judge.harness, model: judge.model, reasoning: judge.reasoning, timeoutSeconds: 30 * 60, approvalPolicy: .allowForAttempt))
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return .init(id: attemptID, runID: run.id, judge: judge, errorMessage: "Judge cancelled before launch.") }
            var evidenceFile: String?
            do {
                var response = ""
                var sawOutput = false
                for try await event in await adapter.events(for: request) {
                    if let evidence { evidenceFile = try await evidence.append(.init(attemptID: attemptID, eventType: event.kind.rawValue, rawJSON: event.rawJSON), runID: run.id) }
                    if event.kind == .outputDelta { response += event.text ?? ""; sawOutput = true }
                    if event.kind == .completed, let text = event.text, !text.isEmpty, (!sawOutput || !response.hasSuffix(text)) { response += text }
                }
                _ = await adapter.shutdown(attemptID: attemptID)
                let parsed = try Self.parse(response)
                guard let candidate = candidates.first(where: { $0.label == parsed.winner }) else { throw JBenchCoreError.storage("Judge selected an invalid winner label.") }
                return .init(id: attemptID, runID: run.id, judge: judge, winningAgentRunID: candidate.agentRunID, winningBlindLabel: candidate.label, reasoning: parsed.reason, rawEvidenceFile: evidenceFile)
            } catch {
                _ = await adapter.shutdown(attemptID: attemptID)
                return .init(id: attemptID, runID: run.id, judge: judge, errorMessage: error.localizedDescription, rawEvidenceFile: evidenceFile)
            }
        }, onCancel: {
            Task { _ = await adapter.shutdown(attemptID: attemptID) }
        })
    }

    public struct ParsedResult: Sendable, Hashable { public let winner: String; public let reason: String; public init(winner: String, reason: String) { self.winner = winner; self.reason = reason } }
    public static func parse(_ text: String) throws -> ParsedResult {
        let cleaned = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") else { throw JBenchCoreError.storage("Judge did not return JSON.") }
        let data = Data(cleaned[start...end].utf8)
        struct Payload: Decodable { let winner: String; let reason: String }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let winner = payload.winner.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reason = payload.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !winner.isEmpty, !reason.isEmpty else { throw JBenchCoreError.storage("Judge JSON must include winner and reason.") }
        return .init(winner: winner, reason: reason)
    }
    private static func label(_ index: Int) -> String {
        var value = index; var result = ""
        repeat { result = String(UnicodeScalar(65 + value % 26)!) + result; value = value / 26 - 1 } while value >= 0
        return result
    }
}
