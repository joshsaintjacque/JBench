import Foundation
import Testing
@testable import JBenchCore

struct RunLifecycleTests {
    @Test func initialPreparationFailureStartsNoHarnessAndAbandonsCreatedWorktree() async throws {
        let fixture = try Fixture()
        let adapter = CountingAdapter()
        let preparation = FailingPreparation(failOnAttempt: 2)
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence, preparation: preparation)

        await #expect(throws: (any Error).self) {
            try await coordinator.start(fixture.draft(configurations: [
                AgentConfiguration(harness: .fake, model: "one"),
                AgentConfiguration(harness: .fake, model: "two")
            ], mode: .editable))
        }

        #expect(await adapter.starts == 0)
        #expect(await preparation.abandoned.count == 1)
    }

    @Test func editableRetryRevalidatesAndUsesFreshRecordedWorktree() async throws {
        let fixture = try Fixture()
        let adapter = CountingAdapter(events: [.init(kind: .started), .init(kind: .failed, text: "deterministic")])
        let preparation = RecordingPreparation()
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence, preparation: preparation)
        let created = try await coordinator.start(fixture.draft(configurations: [
            AgentConfiguration(harness: .fake, model: "one"),
            AgentConfiguration(harness: .fake, model: "two")
        ], mode: .editable))
        let first = try await terminalAttempt(in: created.id, agentIndex: 0, from: coordinator)
        let retry = try await coordinator.retry(failedAttemptID: first.id)
        let snapshot = try #require(await coordinator.snapshot(for: retry.id))
        let initialSnapshot = try #require(await coordinator.snapshot(for: first.id))

        #expect(snapshot.metadata.worktree?.ownedWorktreePath != initialSnapshot.metadata.worktree?.ownedWorktreePath)
        #expect(await preparation.requests.contains(where: { $0.attemptID == retry.id && $0.isRetry && $0.sourceCommit == "abc123" }))
    }

    @Test func sentinelCapabilityRequiresSuccessfulVerificationBeforeStarted() async throws {
        let fixture = try Fixture()
        let adapter = SentinelAdapter()
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence)
        let run = try await coordinator.start(fixture.draft(configurations: [
            AgentConfiguration(harness: .fake, model: "missing-sentinel"),
            AgentConfiguration(harness: .fake, model: "good-sentinel")
        ]))
        let finished = try await terminalRun(run.id, from: coordinator)

        #expect(finished.agents[0].state == .failed)
        #expect(finished.agents[1].state == .completed)
        #expect((await coordinator.snapshot(for: finished.agents[1].attempts[0].id))?.readOnlyVerification?.succeeded == true)
    }

    @Test func shutdownPersistsInterruptedAttemptAndExactHarnessDiagnostic() async throws {
        let fixture = try Fixture()
        let adapter = WaitingAdapter()
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence)
        let run = try await coordinator.start(fixture.draft(configurations: [
            AgentConfiguration(harness: .fake, model: "one", timeoutSeconds: nil),
            AgentConfiguration(harness: .fake, model: "two", timeoutSeconds: nil)
        ]))
        try await Task.sleep(for: .milliseconds(30))
        let report = await coordinator.shutdown()
        let persisted = try #require(await coordinator.run(id: run.id))

        #expect(persisted.endedAt != nil)
        #expect(persisted.agents.allSatisfy { $0.state == .interrupted })
        #expect(report.diagnostics.count == 2)
        #expect(report.diagnostics.allSatisfy { !$0.protocolShutdownCompleted && $0.detail == "server still needs termination" })
        #expect(await adapter.shutdowns == 2)
        #expect(persisted.agents.allSatisfy { $0.attempts.last?.ownership.processIdentity == "jbench-test-process" })
        #expect(persisted.agents.allSatisfy { $0.attempts.last?.protocolSessionID?.hasPrefix("session-") == true })
    }

    @Test func runPersistsHarnessVersionAndNonIdentityBlindOrder() async throws {
        let fixture = try Fixture()
        let adapter = CountingAdapter(events: [.init(kind: .started), .init(kind: .completed)])
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence)
        var draft = fixture.draft(configurations: [
            AgentConfiguration(harness: .fake, model: "one"),
            AgentConfiguration(harness: .fake, model: "two")
        ])
        draft.harnessVersions = [.fake: "fixture-1.0 / adapter-contract-1"]
        draft.integrationProtocolVersions = [.fake: "fixture-stream-v1"]
        let created = try await coordinator.start(draft)
        try await Task.sleep(for: .milliseconds(40))
        let run = try #require(await coordinator.run(id: created.id))

        #expect(run.harnessVersions[.fake] == "fixture-1.0 / adapter-contract-1")
        #expect(run.integrationProtocolVersions?[.fake] == "fixture-stream-v1")
        #expect(run.agents.map(\.blindReviewOrder) == [1, 0])
    }

    @Test func terminalStateWaitsForAdapterShutdown() async throws {
        let fixture = try Fixture()
        let adapter = DelayedShutdownAdapter()
        let coordinator = RunCoordinator(adapters: [adapter], history: fixture.history, evidence: fixture.evidence)
        let created = try await coordinator.start(fixture.draft(configurations: [
            AgentConfiguration(harness: .fake, model: "one"),
            AgentConfiguration(harness: .fake, model: "two")
        ]))

        try await Task.sleep(for: .milliseconds(30))
        let stopping = try #require(await coordinator.run(id: created.id))
        #expect(stopping.agents.contains { !$0.state.isTerminal })
        try await Task.sleep(for: .milliseconds(160))
        let stopped = try #require(await coordinator.run(id: created.id))
        #expect(stopped.agents.allSatisfy { $0.state == .completed })
        #expect(await adapter.shutdowns == 2)
    }

    private func terminalAttempt(in runID: UUID, agentIndex: Int, from coordinator: RunCoordinator) async throws -> AgentAttempt {
        for _ in 0..<200 {
            if let attempt = try await coordinator.run(id: runID)?.agents[agentIndex].attempts.last, attempt.state.isTerminal {
                return attempt
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JBenchCoreError.storage("Timed out waiting for the provider-free fixture attempt to finish.")
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

private struct Fixture {
    let root: URL
    let history: SQLiteHistoryStore
    let evidence: EvidenceStore

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "jbench-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        history = try SQLiteHistoryStore(databaseURL: root.appending(path: "history.sqlite"))
        evidence = try EvidenceStore(rootDirectory: root.appending(path: "evidence", directoryHint: .isDirectory))
    }

    func draft(configurations: [AgentConfiguration], mode: ExecutionMode = .readOnly) -> RunDraft {
        .init(prompt: "exact prompt", directoryPath: root.path, repositoryState: .cleanGit, sourceCommit: "abc123", executionMode: mode, configurations: configurations)
    }
}

private actor CountingAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = true
    private let suppliedEvents: [AdapterEvent]
    private(set) var starts = 0

    init(events: [AdapterEvent] = [.init(kind: .started), .init(kind: .failed, text: "failed")]) { suppliedEvents = events }
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        starts += 1
        return AsyncThrowingStream { continuation in
            for event in suppliedEvents { continuation.yield(event) }
            continuation.finish()
        }
    }
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
}

private actor FailingPreparation: AttemptPreparationService {
    let failOnAttempt: Int
    private var sequence = 0
    private(set) var abandoned: [AttemptPreparation] = []
    init(failOnAttempt: Int) { self.failOnAttempt = failOnAttempt }
    func validate(draft: RunDraft) async throws {}
    func prepare(_ request: AttemptPreparationRequest) async throws -> AttemptPreparation {
        sequence += 1
        if sequence == failOnAttempt { throw JBenchCoreError.storage("worktree creation failed") }
        return AttemptPreparation(directoryPath: request.originalDirectoryPath + "/attempt-\(request.attemptID)", lifecycle: .init(worktree: WorktreeRecord(attemptID: request.attemptID, originalRepositoryPath: request.originalDirectoryPath, sourceCommit: request.sourceCommit ?? "", ownedWorktreePath: request.originalDirectoryPath + "/attempt-\(request.attemptID)")))
    }
    func abandon(_ preparation: AttemptPreparation) async -> String? { abandoned.append(preparation); return nil }
}

private actor RecordingPreparation: AttemptPreparationService {
    private(set) var requests: [AttemptPreparationRequest] = []
    func validate(draft: RunDraft) async throws {}
    func prepare(_ request: AttemptPreparationRequest) async throws -> AttemptPreparation {
        requests.append(request)
        let path = request.originalDirectoryPath + "/owned-\(request.attemptID.uuidString)"
        return AttemptPreparation(directoryPath: path, lifecycle: .init(worktree: WorktreeRecord(attemptID: request.attemptID, originalRepositoryPath: request.originalDirectoryPath, sourceCommit: request.sourceCommit ?? "", ownedWorktreePath: path)))
    }
    func abandon(_ preparation: AttemptPreparation) async -> String? { nil }
}

private actor SentinelAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = false
    func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability { .configuredRestrictionsRequireSentinel(name: "Denied mutation tools") }
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        let events: [AdapterEvent] = request.configuration.model == "good-sentinel"
            ? [.init(kind: .readOnlyVerification, readOnlyVerification: .init(succeeded: true, detail: "sentinel unchanged")), .init(kind: .started), .init(kind: .completed)]
            : [.init(kind: .started), .init(kind: .completed)]
        return AsyncThrowingStream { continuation in for event in events { continuation.yield(event) }; continuation.finish() }
    }
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
}

private actor WaitingAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = true
    private(set) var shutdowns = 0
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(kind: .lifecycle, lifecycle: .init(ownership: .init(processID: 100, processIdentity: "jbench-test-process"), protocolSessionID: "session-\(request.attemptID)")))
            continuation.yield(.init(kind: .started))
            continuation.onTermination = { _ in }
        }
    }
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult { shutdowns += 1; return .init(completedGracefully: false, detail: "server still needs termination") }
}

private actor DelayedShutdownAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .fake
    nonisolated let supportsVerifiedReadOnly = true
    private(set) var shutdowns = 0
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(kind: .started))
            continuation.yield(.init(kind: .completed))
            continuation.finish()
        }
    }
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    func cancel(attemptID: UUID) async {}
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult {
        shutdowns += 1
        try? await Task.sleep(for: .milliseconds(100))
        return .completed
    }
}
