import Foundation
import Testing
@testable import JBenchCore

struct SQLiteHistoryStoreTests {
    @Test func worktreesSurviveRepeatedRunSavesAndStoreReopen() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-worktree-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "history.sqlite")
        let configuration = AgentConfiguration(harness: .fake, model: "fixture")
        let runID = UUID()
        let firstAgentID = UUID()
        let secondAgentID = UUID()
        let firstAttempt = AgentAttempt(agentRunID: firstAgentID, number: 1, state: .running, requested: configuration)
        let secondAttempt = AgentAttempt(agentRunID: secondAgentID, number: 1, state: .running, requested: configuration)
        var run = try BenchmarkRun(
            id: runID,
            prompt: "preserve worktrees",
            directoryPath: "/tmp/project",
            repositoryState: .cleanGit,
            executionMode: .editable,
            rawEvidenceDirectory: root.path,
            agents: [
                .init(id: firstAgentID, runID: runID, displayOrder: 0, requested: configuration, attempts: [firstAttempt]),
                .init(id: secondAgentID, runID: runID, displayOrder: 1, requested: configuration, attempts: [secondAttempt])
            ]
        )
        let firstWorktree = WorktreeRecord(attemptID: firstAttempt.id, originalRepositoryPath: "/tmp/project", sourceCommit: "first", ownedWorktreePath: "/tmp/first-worktree")
        let secondWorktree = WorktreeRecord(attemptID: secondAttempt.id, originalRepositoryPath: "/tmp/project", sourceCommit: "second", ownedWorktreePath: "/tmp/second-worktree")

        do {
            let store = try SQLiteHistoryStore(databaseURL: database)
            try await store.saveRun(run, worktrees: [firstWorktree, secondWorktree])

            run.agents[0].attempts[0].state = .completed
            run.agents[0].attempts[0].finalResponse = "first updated"
            run.agents[1].attempts[0].state = .completed
            run.agents[1].attempts[0].finalResponse = "second updated"
            try await store.saveRun(run)
            #expect(Set(try await store.worktrees(for: runID)) == Set([firstWorktree, secondWorktree]))
        }

        let reopened = try SQLiteHistoryStore(databaseURL: database)
        #expect(Set(try await reopened.worktrees(for: runID)) == Set([firstWorktree, secondWorktree]))
        #expect(try await reopened.run(id: runID) == run)
    }

    @Test func atomicRunSaveRejectsAnUnassociatedWorktreeWithoutPersistingTheRun() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-atomic-worktree-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let configuration = AgentConfiguration(harness: .fake, model: "fixture")
        let runID = UUID()
        let agentID = UUID()
        let run = try BenchmarkRun(
            id: runID,
            prompt: "atomic worktree save",
            directoryPath: "/tmp/project",
            repositoryState: .cleanGit,
            executionMode: .editable,
            rawEvidenceDirectory: root.path,
            agents: [.init(id: agentID, runID: runID, displayOrder: 0, requested: configuration, attempts: [.init(agentRunID: agentID, number: 1, requested: configuration)]), .init(runID: runID, displayOrder: 1, requested: configuration)]
        )
        let unassociated = WorktreeRecord(attemptID: UUID(), originalRepositoryPath: "/tmp/project", sourceCommit: "abc", ownedWorktreePath: "/tmp/unassociated-worktree")

        await #expect(throws: JBenchCoreError.self) {
            try await store.saveRun(run, worktrees: [unassociated])
        }
        #expect(try await store.run(id: runID) == nil)
        #expect(try await store.worktrees(for: runID).isEmpty)
    }

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
