import Foundation
import Testing
@testable import JBenchCore

struct HistoryLifecycleTests {
    private func makeRun(id: UUID, evidence: URL, agentID: UUID? = nil) throws -> BenchmarkRun {
        let first = AgentConfiguration(harness: .fake, model: "fixture")
        let second = AgentConfiguration(harness: .fake, model: "fixture-2")
        let firstID = agentID ?? UUID()
        let a = AgentRun(id: firstID, runID: id, displayOrder: 0, requested: first, attempts: [AgentAttempt(agentRunID: firstID, number: 1, state: .completed, requested: first, finalResponse: "answer")])
        let bID = UUID()
        let b = AgentRun(id: bID, runID: id, displayOrder: 1, requested: second, attempts: [AgentAttempt(agentRunID: bID, number: 1, state: .completed, requested: second, finalResponse: "other")])
        return try BenchmarkRun(id: id, prompt: "history lifecycle fixture", directoryPath: "/tmp/project", repositoryState: .cleanGit, executionMode: .readOnly, rawEvidenceDirectory: evidence.path, agents: [a, b])
    }

    @Test func verdictSurvivesStoreReopen() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "history.sqlite")
        let runID = UUID()
        let verdict: Verdict
        do {
            let store = try SQLiteHistoryStore(databaseURL: database)
            let run = try makeRun(id: runID, evidence: root)
            try await store.saveRun(run)
            verdict = Verdict(runID: runID, winningAgentRunID: run.agents[0].id, note: "keep lane two")
            try await store.saveVerdict(verdict)
        }
        let reopened = try SQLiteHistoryStore(databaseURL: database)
        let restored = try #require(await reopened.verdict(for: runID))
        #expect(restored == verdict)
        #expect(try await reopened.run(id: runID)?.prompt == "history lifecycle fixture")
    }

    @Test func deletionPreviewBlocksPendingAndAllowsTransferred() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let runID = UUID()
        let run = try makeRun(id: runID, evidence: root)
        try await store.saveRun(run)
        let attemptID = try #require(run.agents.first?.attempts.first?.id)
        let pending = WorktreeRecord(attemptID: attemptID, originalRepositoryPath: "/tmp/project", sourceCommit: "abc", ownedWorktreePath: "/tmp/jbench-worktree", disposition: .pending)
        try await store.saveWorktree(pending)
        let blocked = try #require(await store.deletionPreview(for: runID))
        #expect(!blocked.canDelete)
        do {
            try await store.deleteRun(id: runID, confirmation: HistoryDeletionConfirmation(runIDs: [runID]))
            Issue.record("pending worktree deletion unexpectedly succeeded")
        } catch {
            #expect(error as? JBenchCoreError != nil)
        }

        var transferred = pending
        transferred.disposition = .transferred
        transferred.transferredPath = "/tmp/kept-result"
        try await store.saveWorktree(transferred)
        let allowed = try #require(await store.deletionPreview(for: runID))
        #expect(allowed.canDelete)
        #expect(allowed.transferredWorktrees.count == 1)
        try await store.deleteRun(id: runID, confirmation: HistoryDeletionConfirmation(runIDs: [runID]))
        #expect(try await store.run(id: runID) == nil)
        #expect(FileManager.default.fileExists(atPath: "/tmp/kept-result") == false)
    }

    @Test func deleteAllRequiresAnExactPreviewSet() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-delete-all-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let first = try makeRun(id: UUID(), evidence: root.appending(path: "evidence-1"))
        let second = try makeRun(id: UUID(), evidence: root.appending(path: "evidence-2"))
        try await store.saveRun(first)
        try await store.saveRun(second)

        await #expect(throws: (any Error).self) {
            try await store.deleteAll(confirmation: .init(runIDs: [first.id]))
        }
        let ids = Set([first.id, second.id])
        try await store.deleteAll(confirmation: .init(runIDs: ids))
        #expect(try await store.search().isEmpty)
    }
}
