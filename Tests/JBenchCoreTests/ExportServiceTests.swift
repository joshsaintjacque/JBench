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
    #expect(manifest.run.directoryPath == "/tmp/example")
    #expect(manifest.verdict?.winningAgentRunID == firstRunID)
    #expect(manifest.verdict?.note == "Clearer answer")
    #expect(manifest.evidence.allSatisfy { !$0.path.hasPrefix("/") && $0.sha256.count == 64 })
    #expect(manifest.patches.count == 1)
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
