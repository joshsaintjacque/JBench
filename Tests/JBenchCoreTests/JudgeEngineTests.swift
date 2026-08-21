import Foundation
import Testing
@testable import JBenchCore

struct JudgeEngineTests {
    @Test func blindOrderAndIdentityAreStableAndPacketOmitsHarnessMetadata() async throws {
        let first = UUID(); let second = UUID(); let runID = UUID()
        let run = try makeRun(id: runID, agents: [completed(first, runID: runID, order: 1, blind: 0, response: "first"), completed(second, runID: runID, order: 0, blind: 1, response: "second")], judges: [judge()])
        #expect(JudgeEngine.blindCandidates(for: run).map(\.label) == ["A", "B"])
        #expect(JudgeEngine.blindCandidates(for: run).map(\.agentRunID) == [first, second])
        let adapter = CapturingJudgeAdapter(response: #"{"winner":"B","reason":"better"}"#)
        let votes = await JudgeEngine(adapters: [adapter]).judge(run: run)
        #expect(votes.first?.winningAgentRunID == second)
        let prompt = await adapter.prompt
        #expect(prompt?.contains("fake") == false)
        #expect(prompt?.contains("judge-model") == false)
        #expect(prompt?.contains("Candidate A") == true)
    }

    @Test func failedEarlierLaneDoesNotRelabelLaterBlindCandidate() throws {
        let runID = UUID(); let failedID = UUID(); let winnerID = UUID(); let thirdID = UUID()
        let config = AgentConfiguration(harness: .fake, model: "candidate")
        let failed = AgentRun(id: failedID, runID: runID, displayOrder: 0, blindReviewOrder: 0, requested: config, attempts: [.init(agentRunID: failedID, number: 1, state: .failed, requested: config)])
        let run = try makeRun(id: runID, agents: [failed, completed(winnerID, runID: runID, order: 1, blind: 1, response: "winner"), completed(thirdID, runID: runID, order: 2, blind: 2, response: "third")], judges: [])
        #expect(JudgeEngine.blindCandidates(for: run).map(\.label) == ["B", "C"])
    }

    @Test func parsesPlainAndFencedJSONAndRejectsInvalidWinner() async throws {
        #expect(try JudgeEngine.parse(#"{"winner":"A","reason":"clear"}"#).winner == "A")
        #expect(try JudgeEngine.parse("```json\n{\"winner\":\"B\",\"reason\":\"taste\"}\n```").reason == "taste")
        let runID = UUID(); let a = UUID(); let b = UUID()
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: [judge()])
        let votes = await JudgeEngine(adapters: [CapturingJudgeAdapter(response: #"{"winner":"Z","reason":"no"}"#)]).judge(run: run)
        #expect(votes.count == 1); #expect(votes[0].winningAgentRunID == nil); #expect(votes[0].errorMessage != nil)
        #expect(try JudgeEngine.parse(#" {"winner":" b ","reason":"  concise  "} "#).winner == "B")
        #expect(try JudgeEngine.parse(#" {"winner":" b ","reason":"  concise  "} "#).reason == "concise")
    }

    @Test func judgeFailuresAreIsolatedAndJudgeCountIsUnbounded() async throws {
        let runID = UUID(); let a = UUID(); let b = UUID()
        let judges = (0..<9).map { judge(name: "J\($0)", model: $0 == 4 ? "fail" : "ok") }
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: judges)
        let votes = await JudgeEngine(adapters: [CapturingJudgeAdapter(response: #"{"winner":"A","reason":"ok"}"#, failingModel: "fail")]).judge(run: run)
        #expect(votes.count == 9); #expect(votes.filter { $0.winningAgentRunID != nil }.count == 8); #expect(votes.contains { $0.errorMessage != nil })
    }

    @Test func oldRunAndDraftJSONDecodeWithoutJudgeFields() throws {
        let runID = UUID(); let a = UUID(); let b = UUID(); let config = AgentConfiguration(harness: .fake, model: "x")
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: [])
        var data = try JSONEncoder().encode(run); var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["judgeConfigurations"] = nil; object["judgeVotes"] = nil; data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(BenchmarkRun.self, from: data).judgeConfigurations.isEmpty)
        let draft = RunDraft(prompt: "p", directoryPath: "/tmp", repositoryState: .cleanGit, executionMode: .readOnly, configurations: [config, config])
        var draftData = try JSONEncoder().encode(draft); var draftObject = try #require(JSONSerialization.jsonObject(with: draftData) as? [String: Any]); draftObject["judgeConfigurations"] = nil; draftObject["judgeVotes"] = nil; draftData = try JSONSerialization.data(withJSONObject: draftObject)
        #expect(try JSONDecoder().decode(RunDraft.self, from: draftData).judgeVotes.isEmpty)
    }

    @Test func judgeVoteRoundTripsInSQLite() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "judge-vote-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite")); let runID = UUID(); let a = UUID(); let b = UUID()
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: [judge()])
        try await store.saveRun(run); let vote = JudgeVote(runID: runID, judge: judge(), winningAgentRunID: a, winningBlindLabel: "A", reasoning: "clear"); try await store.saveJudgeVote(vote)
        #expect(try await store.judgeVotes(for: runID) == [vote])
        var cleared = run; cleared.judgeVotes = []
        try await store.saveRun(cleared)
        #expect(try await store.judgeVotes(for: runID).isEmpty)
    }

    @Test func judgeEvidenceUsesVoteIDAndRetainsNativeEvents() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "judge-evidence-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try EvidenceStore(rootDirectory: root)
        let runID = UUID(); let a = UUID(); let b = UUID(); let configuration = judge()
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: [configuration])
        let engine = JudgeEngine(adapters: [CapturingJudgeAdapter(response: #"{"winner":"A","reason":"native"}"#)], evidence: evidence)
        let votes = await engine.judge(run: run)
        let secondVotes = await engine.judge(run: run)
        let vote = try #require(votes.first); let secondVote = try #require(secondVotes.first)
        #expect(vote.id != configuration.id); #expect(vote.id != secondVote.id)
        let records = try await evidence.records(runID: runID, attemptID: vote.id)
        #expect(records.count == 2); #expect(records.contains { $0.rawJSON.contains("output") })
        #expect(try await evidence.records(runID: runID, attemptID: secondVote.id).count == 2)
    }

    @Test func judgesRunConcurrentlyWithinConfiguredLimitAndKeepConfigurationOrder() async throws {
        let runID = UUID(); let a = UUID(); let b = UUID()
        let judges = (0..<7).map { judge(name: "J\($0)", model: "model-\($0)") }
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: judges)
        let adapter = ConcurrencyProbeAdapter()
        let releaseTask = Task { await adapter.waitForTwoActive() }
        let votes = await JudgeEngine(adapters: [adapter], maxConcurrentJudges: 2).judge(run: run)
        await releaseTask.value

        #expect(votes.map(\.judge.name) == judges.map(\.name))
        #expect(votes.allSatisfy { $0.winningBlindLabel == "A" })
        let maximum = await adapter.maximumActive
        #expect(maximum > 1)
        #expect(maximum <= 2)
    }

    @Test func cancellingJudgeShutsDownOwnedAttemptWithoutDeadlock() async throws {
        let runID = UUID(); let a = UUID(); let b = UUID()
        let run = try makeRun(id: runID, agents: [completed(a, runID: runID, order: 0, blind: 0, response: "a"), completed(b, runID: runID, order: 1, blind: 1, response: "b")], judges: [judge()])
        let adapter = CancellationProbeAdapter()
        let completion = CompletionProbe()
        let task = Task {
            let votes = await JudgeEngine(adapters: [adapter]).judge(run: run)
            await completion.markComplete()
            return votes
        }
        let attemptID = await adapter.waitForStarted()
        task.cancel()

        var shutdownObserved = false
        for _ in 0..<100 {
            if (await adapter.shutdownIDs).contains(attemptID) { shutdownObserved = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shutdownObserved)
        var completionObserved = false
        for _ in 0..<100 {
            if await completion.isComplete { completionObserved = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completionObserved)
        _ = await task.value
    }

    private func judge(name: String = "Judge", model: String = "judge-model") -> JudgeConfiguration { .init(name: name, harness: .fake, model: model, steeringPrompt: "focus") }
    private func completed(_ id: UUID, runID: UUID, order: Int, blind: Int, response: String) -> AgentRun { let c = AgentConfiguration(harness: .fake, model: "candidate-model"); return .init(id: id, runID: runID, displayOrder: order, blindReviewOrder: blind, requested: c, attempts: [.init(agentRunID: id, number: 1, state: .completed, requested: c, finalResponse: response)]) }
    private func makeRun(id: UUID, agents: [AgentRun], judges: [JudgeConfiguration]) throws -> BenchmarkRun { try .init(id: id, prompt: "p", directoryPath: "/tmp", repositoryState: .cleanGit, executionMode: .readOnly, rawEvidenceDirectory: "/tmp", agents: agents, judgeConfigurations: judges) }
}

private actor CapturingJudgeAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake; nonisolated let supportsVerifiedReadOnly = true
    let response: String; let failingModel: String?; private(set) var prompt: String?
    init(response: String, failingModel: String? = nil) { self.response = response; self.failingModel = failingModel }
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> { prompt = request.prompt; if request.configuration.model == failingModel { return AsyncThrowingStream { $0.finish(throwing: JBenchCoreError.storage("failed")) } }; return AsyncThrowingStream { continuation in continuation.yield(.init(kind: .outputDelta, text: response, rawJSON: "{\"event\":\"output\"}")); continuation.yield(.init(kind: .completed, rawJSON: "{\"event\":\"completed\"}")); continuation.finish() } }
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
}

private actor ConcurrencyProbeAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = true
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        enter()
        return AsyncThrowingStream { continuation in
            Task {
                await self.waitForRelease()
                continuation.yield(.init(kind: .outputDelta, text: #"{"winner":"A","reason":"probe"}"#))
                continuation.yield(.init(kind: .completed))
                continuation.finish()
                self.leave()
            }
        }
    }

    func waitForTwoActive() async {
        if active >= 2 { release(); return }
        await withCheckedContinuation { continuation in activeWaiter = continuation }
        release()
    }

    private func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
        if active >= 2 { activeWaiter?.resume(); activeWaiter = nil }
    }

    private func leave() { active -= 1 }

    private func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
    }

    private func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult { .completed }
}

private actor CancellationProbeAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = true
    private var continuations: [UUID: AsyncThrowingStream<AdapterEvent, Error>.Continuation] = [:]
    private(set) var startedIDs: [UUID] = []
    private var startedWaiter: CheckedContinuation<UUID, Never>?
    private(set) var shutdownIDs: [UUID] = []

    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            continuations[request.attemptID] = continuation
            startedIDs.append(request.attemptID)
            startedWaiter?.resume(returning: request.attemptID)
            startedWaiter = nil
            continuation.yield(.init(kind: .started))
        }
    }

    func waitForStarted() async -> UUID {
        if let attemptID = startedIDs.first { return attemptID }
        return await withCheckedContinuation { startedWaiter = $0 }
    }

    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult {
        shutdownIDs.append(attemptID)
        continuations.removeValue(forKey: attemptID)?.finish()
        return .completed
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}
