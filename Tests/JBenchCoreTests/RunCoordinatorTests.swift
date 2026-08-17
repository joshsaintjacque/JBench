import Foundation
import Testing
@testable import JBenchCore

struct RunCoordinatorTests {
    @Test func retainsAndPersistsRecentNormalizedActivity() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-activity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let evidence = try EvidenceStore(rootDirectory: root.appending(path: "evidence", directoryHint: .isDirectory))
        let activity = (0...AgentAttempt.maximumRetainedActivityEntries).map { AdapterEvent(kind: .activity, text: "activity-\($0)") }
        let fake = FakeHarnessAdapter(plans: ["activity": .init(events: [.init(kind: .started)] + activity + [.init(kind: .completed)], eventDelay: .zero)])
        let coordinator = RunCoordinator(adapters: [fake], history: history, evidence: evidence)
        let created = try await coordinator.start(.init(prompt: "report activity", directoryPath: root.path, repositoryState: .cleanGit, executionMode: .readOnly, configurations: [.init(harness: .fake, model: "activity"), .init(harness: .fake, model: "other")]))

        var completedRun: BenchmarkRun?
        for _ in 0..<200 {
            if let run = try await coordinator.run(id: created.id), run.agents.allSatisfy({ $0.state.isTerminal }) {
                completedRun = run
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempt = try #require(completedRun?.agents[0].attempts[0])
        #expect(attempt.activity.count == AgentAttempt.maximumRetainedActivityEntries)
        #expect(attempt.activity.first?.text == "activity-1")
        #expect(attempt.activity.last?.text == "activity-100")

        let reopened = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        let persisted = try #require((try await reopened.run(id: created.id))?.agents[0].attempts[0])
        #expect(persisted.activity == attempt.activity)
    }

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
        let finished = try await terminalRun(created.id, from: coordinator)
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
        let finished = try await terminalRun(run.id, from: coordinator)
        #expect(finished.agents[0].state == .timedOut)
        #expect(finished.agents[1].state == .completed)
    }

    private func terminalRun(_ id: UUID, from coordinator: RunCoordinator) async throws -> BenchmarkRun {
        for _ in 0..<200 {
            if let run = try await coordinator.run(id: id), run.agents.allSatisfy({ $0.state.isTerminal }) {
                return run
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JBenchCoreError.storage("Timed out waiting for the provider-free fixture run to finish.")
    }
}
