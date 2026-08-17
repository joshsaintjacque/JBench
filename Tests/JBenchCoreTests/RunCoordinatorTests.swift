import Foundation
import Testing
@testable import JBenchCore

struct RunCoordinatorTests {
    @Test func runsLanesInParallelAndRetainsPartialFailure() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let evidence = try EvidenceStore(rootDirectory: root.appending(path: "evidence", directoryHint: .isDirectory))
        let fake = FakeHarnessAdapter(plans: [
            "good": .successful(response: "good markdown"),
            "bad": .init(events: [.init(kind: .started), .init(kind: .failed, text: "deterministic failure")])
        ])
        let coordinator = RunCoordinator(adapters: [fake], history: history, evidence: evidence)
        let draft = RunDraft(prompt: "exact visible prompt", directoryPath: root.path, repositoryState: .cleanGit, executionMode: .readOnly, configurations: [AgentConfiguration(harness: .fake, model: "good"), AgentConfiguration(harness: .fake, model: "bad")])
        let created = try await coordinator.start(draft)
        try await Task.sleep(for: .milliseconds(100))
        let finished = try #require(await coordinator.run(id: created.id))
        #expect(finished.state == .partiallyCompleted)
        #expect(finished.agents[0].attempts[0].finalResponse == "good markdown")
        #expect(finished.agents[1].attempts[0].state == .failed)
        #expect(finished.agents.allSatisfy { $0.attempts[0].rawEventFile != nil })
        #expect(try await evidence.records(runID: created.id, attemptID: finished.agents[0].attempts[0].id).count == 3)
    }

    @Test func timeoutCancelsOnlyItsLane() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-timeout-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let evidence = try EvidenceStore(rootDirectory: root.appending(path: "evidence", directoryHint: .isDirectory))
        let fake = FakeHarnessAdapter(plans: ["slow": .init(events: [.init(kind: .started), .init(kind: .completed)], eventDelay: .milliseconds(100)), "fast": .successful(response: "done")])
        let coordinator = RunCoordinator(adapters: [fake], history: history, evidence: evidence)
        let run = try await coordinator.start(.init(prompt: "same", directoryPath: root.path, repositoryState: .cleanGit, executionMode: .readOnly, configurations: [AgentConfiguration(harness: .fake, model: "slow", timeoutSeconds: 0.01), AgentConfiguration(harness: .fake, model: "fast")]))
        try await Task.sleep(for: .milliseconds(150))
        let finished = try #require(await coordinator.run(id: run.id))
        #expect(finished.agents[0].state == .timedOut)
        #expect(finished.agents[1].state == .completed)
    }
}
