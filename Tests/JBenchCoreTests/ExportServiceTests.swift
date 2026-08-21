import Foundation
import Testing
@testable import JBenchCore

@Test func exportsReportWithRunDetailsAndPortableBundle() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("jbench-export-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let evidence = root.appendingPathComponent("source-evidence", isDirectory: true)
    try fm.createDirectory(at: evidence, withIntermediateDirectories: true)

    let firstID = UUID(); let secondID = UUID()
    try Data(#"{"event":"done"}"#.utf8).write(to: evidence.appendingPathComponent("first.jsonl"))
    try Data(#"{"event":"done"}"#.utf8).write(to: evidence.appendingPathComponent("second.jsonl"))
    let firstConfig = AgentConfiguration(harness: .codex, model: "sol", reasoning: "high")
    let secondConfig = AgentConfiguration(harness: .openCode, model: "deepseek-v4", reasoning: "max")
    let firstAttempt = AgentAttempt(id: firstID, agentRunID: UUID(), number: 1, state: .completed, requested: firstConfig, observed: ObservedSettings(model: ObservedValue("sol-native", provenance: .harnessReported), reasoning: ObservedValue("high", provenance: .harnessReported)), metrics: AttemptMetrics(elapsedSeconds: 1.2, elapsedProvenance: .locallyMeasured), finalResponse: "First answer", rawEventFile: "first.jsonl")
    let secondAttempt = AgentAttempt(id: secondID, agentRunID: UUID(), number: 1, state: .failed, requested: secondConfig, errorMessage: "server stopped", rawEventFile: "second.jsonl")
    let firstRunID = firstAttempt.agentRunID; let secondRunID = secondAttempt.agentRunID
    let run = try BenchmarkRun(prompt: "Compare these answers", directoryPath: "/tmp/example", repositoryState: .cleanGit, sourceCommit: "abc123", executionMode: .readOnly, rawEvidenceDirectory: evidence.path, agents: [AgentRun(id: firstRunID, runID: UUID(), displayOrder: 0, requested: firstConfig, attempts: [firstAttempt]), AgentRun(id: secondRunID, runID: UUID(), displayOrder: 1, requested: secondConfig, attempts: [secondAttempt])])
    let verdict = Verdict(runID: run.id, winningAgentRunID: firstRunID, note: "Clearer answer")
    let service = ExportService()

    let report = try service.exportMarkdownReport(run, verdict: verdict, to: root)
    let markdown = try String(contentsOf: report, encoding: .utf8)
    #expect(markdown.contains("Compare these answers"))
    #expect(markdown.contains("Requested reasoning"))
    #expect(markdown.contains("First answer"))
    #expect(markdown.contains("server stopped"))
    #expect(markdown.contains("Clearer answer"))

    let patch = root.appendingPathComponent("answer.patch")
    try Data("diff --git a/a b/a\n".utf8).write(to: patch)
    let bundle = try service.exportEvidenceBundle(run, verdict: verdict, patches: [patch], to: root)
    #expect(fm.fileExists(atPath: bundle.reportURL.path))
    #expect(fm.fileExists(atPath: bundle.manifestURL.path))
    #expect(bundle.files.count == 3)
    let manifestData = try Data(contentsOf: bundle.manifestURL)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(PortableEvidenceManifest.self, from: manifestData)
    #expect(manifest.run.rawEvidenceDirectory == "evidence")
    #expect(manifest.run.agents.allSatisfy { $0.attempts.allSatisfy { attempt in
        guard let rawEventFile = attempt.rawEventFile else { return true }
        return !rawEventFile.contains("/")
    } })
    #expect(manifest.run.directoryPath == "/tmp/example")
    #expect(manifest.verdict?.winningAgentRunID == firstRunID)
    #expect(manifest.verdict?.note == "Clearer answer")
    #expect(manifest.evidence.allSatisfy { !$0.path.hasPrefix("/") && $0.sha256.count == 64 })
    #expect(manifest.patches.count == 1)
}

@Test func exportsAIJudgesAndResolvesWinningCandidate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jbench-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstConfiguration = AgentConfiguration(harness: .codex, model: "candidate-one")
    let secondConfiguration = AgentConfiguration(harness: .openCode, model: "candidate-two")
    let firstID = UUID(); let secondID = UUID()
    let first = AgentRun(id: firstID, runID: UUID(), displayOrder: 0, requested: firstConfiguration, attempts: [AgentAttempt(agentRunID: UUID(), number: 1, state: .completed, requested: firstConfiguration, finalResponse: "one")])
    let second = AgentRun(id: secondID, runID: UUID(), displayOrder: 1, requested: secondConfiguration, attempts: [AgentAttempt(agentRunID: UUID(), number: 1, state: .completed, requested: secondConfiguration, finalResponse: "two")])
    let successJudge = JudgeConfiguration(name: "Correctness", harness: .fake, model: "judge-model", reasoning: "high", steeringPrompt: "Focus on factual correctness.")
    let failedJudge = JudgeConfiguration(name: "Taste", harness: .openCode, model: "taste-model", reasoning: "low")
    let successVote = JudgeVote(runID: UUID(), judge: successJudge, winningAgentRunID: secondID, winningBlindLabel: "A", reasoning: "More accurate.", recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let failedVote = JudgeVote(runID: UUID(), judge: failedJudge, errorMessage: "Judge timed out.", recordedAt: Date(timeIntervalSince1970: 1_700_000_001))
    let run = try BenchmarkRun(prompt: "judge export", directoryPath: "/tmp/example", repositoryState: .nonGit, executionMode: .readOnly, rawEvidenceDirectory: root.path, agents: [first, second], judgeConfigurations: [successJudge, failedJudge], judgeVotes: [successVote, failedVote])

    let report = try ExportService().exportMarkdownReport(run, to: root)
    let markdown = try String(contentsOf: report, encoding: .utf8)
    #expect(markdown.contains("## AI Judges"))
    #expect(markdown.contains("### Correctness"))
    #expect(markdown.contains("**Harness:** `fake`"))
    #expect(markdown.contains("**Reasoning:** `high`"))
    #expect(markdown.contains("Focus on factual correctness."))
    #expect(markdown.contains("**Blind candidate:** `A`"))
    #expect(markdown.contains("**Resolved candidate:** `openCode` / `candidate-two`"))
    #expect(markdown.contains("**Reason:** More accurate."))
    #expect(markdown.contains("**Error:** Judge timed out."))
    #expect(markdown.contains("2023-11-14T22:13:20Z"))
}

@Test func exportedEvidenceReferencesResolveAfterMovingBundle() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("jbench-export-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let evidence = root.appendingPathComponent("source-evidence", isDirectory: true)
    try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
    let config = AgentConfiguration(harness: .fake, model: "fixture")
    let attempt = AgentAttempt(id: UUID(), agentRunID: UUID(), number: 1, state: .completed, requested: config, rawEventFile: "events.jsonl")
    try Data(#"{"event":"done"}"#.utf8).write(to: evidence.appendingPathComponent("events.jsonl"))
    let run = try BenchmarkRun(prompt: "portable export", directoryPath: root.path, repositoryState: .nonGit, executionMode: .readOnly, rawEvidenceDirectory: evidence.path, agents: [AgentRun(runID: UUID(), displayOrder: 0, requested: config, attempts: [attempt]), AgentRun(runID: UUID(), displayOrder: 1, requested: config)])

    let bundle = try ExportService().exportEvidenceBundle(run, to: root)
    let moved = root.appendingPathComponent("moved-bundle", isDirectory: true)
    try fm.moveItem(at: bundle.directory, to: moved)
    let data = try Data(contentsOf: moved.appendingPathComponent("run-manifest.json"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(PortableEvidenceManifest.self, from: data)
    let exportedAttempt = try #require(manifest.run.agents.first?.attempts.first)
    let rawEventFile = try #require(exportedAttempt.rawEventFile)
    let resolvedFile = moved.appendingPathComponent(manifest.run.rawEvidenceDirectory).appendingPathComponent(rawEventFile)

    #expect(fm.fileExists(atPath: resolvedFile.path))
    #expect(try Data(contentsOf: resolvedFile) == Data(#"{"event":"done"}"#.utf8))
}

@Test func exportsJudgeEvidenceIntoPortableBundle() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("jbench-export-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let evidence = root.appendingPathComponent("source-evidence", isDirectory: true)
    try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
    let source = evidence.appendingPathComponent("judge.jsonl")
    try Data(#"{"event":"judge-done"}"#.utf8).write(to: source)

    let configuration = AgentConfiguration(harness: .fake, model: "candidate")
    let first = AgentRun(runID: UUID(), displayOrder: 0, requested: configuration)
    let second = AgentRun(runID: UUID(), displayOrder: 1, requested: configuration)
    let judge = JudgeConfiguration(name: "Correctness", harness: .fake, model: "judge")
    let vote = JudgeVote(runID: UUID(), judge: judge, errorMessage: "Judge failed", rawEvidenceFile: "judge.jsonl")
    let run = try BenchmarkRun(prompt: "portable judge evidence", directoryPath: "/tmp/example", repositoryState: .nonGit, executionMode: .readOnly, rawEvidenceDirectory: evidence.path, agents: [first, second], judgeConfigurations: [judge], judgeVotes: [vote])

    let bundle = try ExportService().exportEvidenceBundle(run, to: root)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(PortableEvidenceManifest.self, from: Data(contentsOf: bundle.manifestURL))
    let exportedReference = try #require(manifest.run.judgeVotes.first?.rawEvidenceFile)
    #expect(exportedReference != "judge.jsonl")
    #expect(fm.fileExists(atPath: bundle.directory.appendingPathComponent("evidence").appendingPathComponent(exportedReference).path))
    #expect(manifest.evidence.contains { $0.path == "evidence/\(exportedReference)" })
    #expect(try Data(contentsOf: bundle.directory.appendingPathComponent("evidence").appendingPathComponent(exportedReference)) == Data(#"{"event":"judge-done"}"#.utf8))
}

@Test func rejectsEvidencePathEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jbench-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = AgentConfiguration(harness: .fake, model: "fixture")
    let attemptID = UUID(); let agentID = UUID()
    let attempt = AgentAttempt(id: attemptID, agentRunID: agentID, number: 1, state: .completed, requested: config, rawEventFile: "../outside.jsonl")
    let run = try BenchmarkRun(prompt: "x", directoryPath: root.path, repositoryState: .nonGit, executionMode: .readOnly, rawEvidenceDirectory: root.path, agents: [AgentRun(id: agentID, runID: UUID(), displayOrder: 0, requested: config, attempts: [attempt]), AgentRun(runID: UUID(), displayOrder: 1, requested: config)])
    #expect(throws: JBenchCoreError.self) { try ExportService().exportEvidenceBundle(run, to: root) }
}
