import Foundation
import Testing
@testable import JBenchCore

struct SQLiteHistoryStoreTests {
    @Test func presetsRunsAttemptsVerdictsAndSearchPersist() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-sqlite-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let first = AgentConfiguration(harness: .fake, model: "alpha")
        let second = AgentConfiguration(harness: .fake, model: "beta")
        let preset = try Preset(name: "Two fake lanes", agents: [first, second])
        try await store.savePreset(preset)
        let savedPresets = try await store.presets()
        #expect(savedPresets.map(\.id) == [preset.id])
        #expect(savedPresets.first?.agents == preset.agents)

        let runID = UUID()
        let agentID = UUID()
        let attempt = AgentAttempt(agentRunID: agentID, number: 1, state: .completed, requested: first, finalResponse: "usable result")
        let agent = AgentRun(id: agentID, runID: runID, displayOrder: 0, requested: first, attempts: [attempt])
        let secondAgent = AgentRun(runID: runID, displayOrder: 1, requested: second, attempts: [AgentAttempt(agentRunID: UUID(), number: 1, state: .completed, requested: second)])
        let run = try BenchmarkRun(id: runID, prompt: "Find the exact answer", directoryPath: "/work/project", repositoryState: .cleanGit, executionMode: .readOnly, rawEvidenceDirectory: root.path, agents: [agent, secondAgent])
        try await store.saveRun(run)
        let restoredRun = try #require(await store.run(id: runID))
        #expect(restoredRun.id == run.id)
        #expect(restoredRun.prompt == run.prompt)
        #expect(restoredRun.agents == run.agents)
        #expect(try await store.search(.init(text: "exact", harness: .fake)).map(\.id) == [runID])
        #expect(try await store.search(.init(model: "bet")).map(\.id) == [runID])
        #expect(try await store.search(.init(model: "missing")).isEmpty)
        #expect(try await store.search(.init(verdictOnly: false)).map(\.id) == [runID])
        let verdict = Verdict(runID: runID, winningAgentRunID: agentID, note: "clear")
        try await store.saveVerdict(verdict)
        let restoredVerdict = try #require(await store.verdict(for: runID))
        #expect(restoredVerdict.id == verdict.id)
        #expect(restoredVerdict.note == "clear")
        #expect(try await store.search(.init(verdictOnly: true)).map(\.id) == [runID])
        #expect(try await store.search(.init(verdictOnly: false)).isEmpty)
    }
}
