import Foundation

public struct HarnessRequest: Sendable, Hashable {
    public var runID: UUID
    public var attemptID: UUID
    public var prompt: String
    public var directoryPath: String
    public var executionMode: ExecutionMode
    public var configuration: AgentConfiguration

    public init(runID: UUID, attemptID: UUID, prompt: String, directoryPath: String, executionMode: ExecutionMode, configuration: AgentConfiguration) {
        self.runID = runID; self.attemptID = attemptID; self.prompt = prompt; self.directoryPath = directoryPath
        self.executionMode = executionMode; self.configuration = configuration
    }
}

/// The contract used to make a read-only lane truthful in the UI. A label or a
/// prompt is never enough: the adapter must describe a concrete restriction.
public enum ReadOnlyCapability: Sendable, Hashable {
    case enforcedSandbox(name: String)
    case configuredRestrictionsRequireSentinel(name: String)
    case unavailable(reason: String)

    public var mayStartReadOnlyRun: Bool {
        switch self { case .enforcedSandbox, .configuredRestrictionsRequireSentinel: true; case .unavailable: false }
    }

    public var requiresSentinel: Bool {
        if case .configuredRestrictionsRequireSentinel = self { return true }
        return false
    }

    public var explanation: String {
        switch self {
        case .enforcedSandbox(let name): return name
        case .configuredRestrictionsRequireSentinel(let name): return "\(name); a write-block sentinel must succeed before prompt execution."
        case .unavailable(let reason): return reason
        }
    }
}

public struct ReadOnlyVerification: Codable, Sendable, Hashable {
    public var succeeded: Bool
    public var detail: String
    public init(succeeded: Bool, detail: String) { self.succeeded = succeeded; self.detail = detail }
}

/// Adapter-provided identifiers are only persisted when the adapter observed them.
/// `worktree` comes from JBench's preparation service, not from a harness claim.
public struct AttemptLifecycleMetadata: Codable, Sendable, Hashable {
    public var ownership: ProcessOwnership?
    public var protocolSessionID: String?
    public var worktree: WorktreeRecord?
    public init(ownership: ProcessOwnership? = nil, protocolSessionID: String? = nil, worktree: WorktreeRecord? = nil) {
        self.ownership = ownership; self.protocolSessionID = protocolSessionID; self.worktree = worktree
    }
}

public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var summary: String
    public var targetPath: String?
    public var permissionCategory: String?
    public init(id: UUID = UUID(), summary: String, targetPath: String? = nil, permissionCategory: String? = nil) {
        self.id = id; self.summary = summary; self.targetPath = targetPath; self.permissionCategory = permissionCategory
    }
}

public enum ApprovalReply: String, Codable, Sendable, Hashable { case approveOnce, approveForAttempt, decline }

public struct AdapterEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case started, outputDelta, activity, observedSettings, metrics, approvalRequest, readOnlyVerification, lifecycle, completed, failed
    }
    public var kind: Kind
    public var text: String?
    public var observed: ObservedSettings?
    public var metrics: AttemptMetrics?
    public var approval: ApprovalRequest?
    public var readOnlyVerification: ReadOnlyVerification?
    public var lifecycle: AttemptLifecycleMetadata?
    /// Retained unchanged as evidence. A real adapter supplies its native wire event here.
    public var rawJSON: String

    public init(kind: Kind, text: String? = nil, observed: ObservedSettings? = nil, metrics: AttemptMetrics? = nil, approval: ApprovalRequest? = nil, readOnlyVerification: ReadOnlyVerification? = nil, lifecycle: AttemptLifecycleMetadata? = nil, rawJSON: String = "{}") {
        self.kind = kind; self.text = text; self.observed = observed; self.metrics = metrics; self.approval = approval
        self.readOnlyVerification = readOnlyVerification; self.lifecycle = lifecycle; self.rawJSON = rawJSON
    }
}

public struct HarnessShutdownResult: Sendable, Hashable {
    public var completedGracefully: Bool
    public var detail: String?
    public init(completedGracefully: Bool, detail: String? = nil) { self.completedGracefully = completedGracefully; self.detail = detail }
    public static let completed = HarnessShutdownResult(completedGracefully: true)
}

public protocol HarnessAdapter: Sendable {
    var kind: HarnessKind { get }
    /// Kept for source compatibility. Implement `readOnlyCapability` for contracts which require a sentinel.
    var supportsVerifiedReadOnly: Bool { get }
    func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability
    func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error>
    func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws
    func cancel(attemptID: UUID) async
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult
}

public extension HarnessAdapter {
    func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability {
        supportsVerifiedReadOnly ? .enforcedSandbox(name: "Adapter declared enforced read-only sandbox") : .unavailable(reason: "This harness version has no verified read-only contract.")
    }
    func shutdown(attemptID: UUID) async -> HarnessShutdownResult { await cancel(attemptID: attemptID); return .completed }
}

public struct RunDraft: Sendable, Hashable {
    public var title: String?
    public var prompt: String
    public var directoryPath: String
    public var repositoryState: RepositoryState
    public var sourceCommit: String?
    public var executionMode: ExecutionMode
    public var harnessVersions: [HarnessKind: String]
    public var integrationProtocolVersions: [HarnessKind: String]
    public var configurations: [AgentConfiguration]
    public init(title: String? = nil, prompt: String, directoryPath: String, repositoryState: RepositoryState, sourceCommit: String? = nil, executionMode: ExecutionMode, harnessVersions: [HarnessKind: String] = [:], integrationProtocolVersions: [HarnessKind: String] = [:], configurations: [AgentConfiguration]) {
        self.title = title; self.prompt = prompt; self.directoryPath = directoryPath; self.repositoryState = repositoryState
        self.sourceCommit = sourceCommit; self.executionMode = executionMode; self.harnessVersions = harnessVersions; self.integrationProtocolVersions = integrationProtocolVersions; self.configurations = configurations
    }
}

public struct AttemptPreparationRequest: Sendable, Hashable {
    public var runID: UUID
    public var attemptID: UUID
    public var attemptNumber: Int
    public var originalDirectoryPath: String
    public var sourceCommit: String?
    public var executionMode: ExecutionMode
    public var configuration: AgentConfiguration
    public var isRetry: Bool

    public init(runID: UUID, attemptID: UUID, attemptNumber: Int, originalDirectoryPath: String, sourceCommit: String?, executionMode: ExecutionMode, configuration: AgentConfiguration, isRetry: Bool) {
        self.runID = runID; self.attemptID = attemptID; self.attemptNumber = attemptNumber; self.originalDirectoryPath = originalDirectoryPath
        self.sourceCommit = sourceCommit; self.executionMode = executionMode; self.configuration = configuration; self.isRetry = isRetry
    }
}

public struct AttemptPreparation: Sendable, Hashable {
    public var directoryPath: String
    public var lifecycle: AttemptLifecycleMetadata
    public init(directoryPath: String, lifecycle: AttemptLifecycleMetadata = .init()) { self.directoryPath = directoryPath; self.lifecycle = lifecycle }
}

/// Editable implementations must revalidate the repository and recorded commit in `prepare`.
/// Initial preparations are completed before a single harness is launched.
public protocol AttemptPreparationService: Sendable {
    func validate(draft: RunDraft) async throws
    func prepare(_ request: AttemptPreparationRequest) async throws -> AttemptPreparation
    func abandon(_ preparation: AttemptPreparation) async -> String?
}

public struct PassthroughAttemptPreparationService: AttemptPreparationService {
    public init() {}
    public func validate(draft: RunDraft) async throws {
        if draft.executionMode == .editable && (draft.repositoryState != .cleanGit || draft.sourceCommit == nil) {
            throw JBenchCoreError.storage("Editable runs require a clean Git repository and recorded source commit.")
        }
    }
    public func prepare(_ request: AttemptPreparationRequest) async throws -> AttemptPreparation {
        if request.executionMode == .editable {
            throw JBenchCoreError.storage("No editable worktree preparation service is configured.")
        }
        return AttemptPreparation(directoryPath: request.originalDirectoryPath)
    }
    public func abandon(_ preparation: AttemptPreparation) async -> String? { nil }
}

public struct AttemptLifecycleSnapshot: Sendable, Hashable {
    public var attemptID: UUID
    public var readOnlyCapability: ReadOnlyCapability?
    public var readOnlyVerification: ReadOnlyVerification?
    public var metadata: AttemptLifecycleMetadata
    public init(attemptID: UUID, readOnlyCapability: ReadOnlyCapability? = nil, readOnlyVerification: ReadOnlyVerification? = nil, metadata: AttemptLifecycleMetadata = .init()) {
        self.attemptID = attemptID; self.readOnlyCapability = readOnlyCapability; self.readOnlyVerification = readOnlyVerification; self.metadata = metadata
    }
}

public struct RunShutdownDiagnostic: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var attemptID: UUID
    public var harness: HarnessKind
    public var protocolShutdownCompleted: Bool
    public var detail: String?
    public var ownership: ProcessOwnership
    public init(id: UUID = UUID(), attemptID: UUID, harness: HarnessKind, protocolShutdownCompleted: Bool, detail: String?, ownership: ProcessOwnership) {
        self.id = id; self.attemptID = attemptID; self.harness = harness; self.protocolShutdownCompleted = protocolShutdownCompleted; self.detail = detail; self.ownership = ownership
    }
}

public struct RunShutdownReport: Sendable, Hashable {
    public var diagnostics: [RunShutdownDiagnostic]
    public var interruptedRunIDs: [UUID]
    public init(diagnostics: [RunShutdownDiagnostic], interruptedRunIDs: [UUID]) { self.diagnostics = diagnostics; self.interruptedRunIDs = interruptedRunIDs }
}

public enum RunUpdate: Sendable, Hashable {
    case runCreated(BenchmarkRun)
    case attemptChanged(runID: UUID, agentRunID: UUID, attempt: AgentAttempt)
    case lifecycleChanged(AttemptLifecycleSnapshot)
    case approvalNeeded(runID: UUID, agentRunID: UUID, attemptID: UUID, request: ApprovalRequest)
    case runFinished(BenchmarkRun)
    case diagnostic(String)
}

public actor RunCoordinator {
    private let adapters: [HarnessKind: any HarnessAdapter]
    private let history: SQLiteHistoryStore
    private let evidence: EvidenceStore
    private let preparation: any AttemptPreparationService
    private var runs: [UUID: BenchmarkRun] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var stoppingAttempts: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<RunUpdate>.Continuation] = [:]
    private var pendingApprovals: [UUID: ApprovalRequest] = [:]
    private var preparations: [UUID: AttemptPreparation] = [:]
    private var lifecycles: [UUID: AttemptLifecycleSnapshot] = [:]
    private var finishedRuns = Set<UUID>()
    private var shuttingDown = false

    public init(adapters: [any HarnessAdapter], history: SQLiteHistoryStore, evidence: EvidenceStore, preparation: any AttemptPreparationService = PassthroughAttemptPreparationService()) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
        self.history = history; self.evidence = evidence; self.preparation = preparation
    }

    public func updates() -> AsyncStream<RunUpdate> {
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in Task { if let self { await self.removeSubscriber(token) } } }
            Task { [weak self] in if let self { await self.addSubscriber(continuation, token: token) } }
        }
    }

    public func start(_ draft: RunDraft) async throws -> BenchmarkRun {
        guard !shuttingDown else { throw JBenchCoreError.storage("JBench is shutting down and cannot start a run.") }
        try Preset.validate(draft.configurations)
        try await preparation.validate(draft: draft)
        guard draft.executionMode != .editable || draft.repositoryState == .cleanGit else {
            throw JBenchCoreError.storage("Editable runs require a clean Git repository.")
        }

        var capabilities: [UUID: ReadOnlyCapability] = [:]
        if draft.executionMode == .readOnly {
            for configuration in draft.configurations {
                guard let adapter = adapters[configuration.harness] else { throw JBenchCoreError.storage("No local adapter is configured for \(configuration.harness.rawValue).") }
                let capability = await adapter.readOnlyCapability(for: configuration)
                guard capability.mayStartReadOnlyRun else { throw JBenchCoreError.storage("\(configuration.harness.rawValue) cannot start a read-only run: \(capability.explanation)") }
                capabilities[configuration.id] = capability
            }
        }

        let runID = UUID()
        let displayOrders = Array(draft.configurations.indices)
        var blindOrders = displayOrders.shuffled()
        if blindOrders == displayOrders { blindOrders.reverse() }
        let agents = draft.configurations.enumerated().map { index, configuration in
            let agentID = UUID()
            return AgentRun(id: agentID, runID: runID, displayOrder: index, blindReviewOrder: blindOrders[index], requested: configuration, attempts: [AgentAttempt(agentRunID: agentID, number: 1, requested: configuration)])
        }
        let directory = try await evidence.makeRunDirectory(runID: runID)
        var run = try BenchmarkRun(id: runID, title: draft.title, prompt: draft.prompt, directoryPath: draft.directoryPath, repositoryState: draft.repositoryState, sourceCommit: draft.sourceCommit, executionMode: draft.executionMode, startedAt: .now, rawEvidenceDirectory: directory.path, harnessVersions: draft.harnessVersions, integrationProtocolVersions: draft.integrationProtocolVersions, agents: agents)

        // Prepare every initial attempt before launching any server. This is what prevents
        // a failed editable worktree creation from producing a partially started comparison.
        var createdPreparations: [AttemptPreparation] = []
        do {
            for agentIndex in run.agents.indices {
                let agent = run.agents[agentIndex]
                let attempt = agent.attempts[0]
                let result = try await preparation.prepare(.init(runID: runID, attemptID: attempt.id, attemptNumber: attempt.number, originalDirectoryPath: draft.directoryPath, sourceCommit: draft.sourceCommit, executionMode: draft.executionMode, configuration: attempt.requested, isRetry: false))
                createdPreparations.append(result)
                preparations[attempt.id] = result
                applyLifecycle(result.lifecycle, to: &run.agents[agentIndex].attempts[0])
                let capability = capabilities[attempt.requested.id]
                let snapshot = AttemptLifecycleSnapshot(attemptID: attempt.id, readOnlyCapability: capability, metadata: result.lifecycle)
                lifecycles[attempt.id] = snapshot
            }
        } catch {
            for result in createdPreparations { if let note = await preparation.abandon(result) { emit(.diagnostic(note)) } }
            for agent in run.agents { preparations[agent.attempts[0].id] = nil; lifecycles[agent.attempts[0].id] = nil }
            throw error
        }

        runs[run.id] = run
        try await persist(run)
        do {
            for agent in run.agents {
                if let record = lifecycles[agent.attempts[0].id]?.metadata.worktree { try await history.saveWorktree(record) }
            }
        } catch {
            for result in createdPreparations { if let note = await preparation.abandon(result) { emit(.diagnostic(note)) } }
            runs[run.id] = nil
            for agent in run.agents { preparations[agent.attempts[0].id] = nil; lifecycles[agent.attempts[0].id] = nil }
            try? await history.deleteRun(id: run.id)
            throw error
        }
        emit(.runCreated(run))
        for agent in run.agents {
            let attemptID = agent.attempts[0].id
            if let snapshot = lifecycles[attemptID] { emit(.lifecycleChanged(snapshot)) }
            await begin(runID: run.id, agentRunID: agent.id, attemptID: attemptID)
        }
        return run
    }

    public func run(id: UUID) async throws -> BenchmarkRun? {
        if let cached = runs[id] { return cached }
        let restored = try await history.run(id: id)
        if let restored {
            runs[id] = restored
            if restored.endedAt != nil { finishedRuns.insert(id) }
        }
        return restored
    }

    public func runs() async throws -> [BenchmarkRun] { try await history.search() }

    public func activeRuns() -> [BenchmarkRun] { runs.values.filter { !$0.agents.allSatisfy { $0.state.isTerminal } }.sorted { $0.createdAt < $1.createdAt } }

    public func snapshot(for attemptID: UUID) -> AttemptLifecycleSnapshot? { lifecycles[attemptID] }

    public func snapshots(for runID: UUID) -> [AttemptLifecycleSnapshot] {
        guard let run = runs[runID] else { return [] }
        return run.agents.flatMap(\.attempts).compactMap { lifecycles[$0.id] }
    }

    public func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability? {
        guard let adapter = adapters[configuration.harness] else { return nil }
        return await adapter.readOnlyCapability(for: configuration)
    }

    public func cancel(attemptID: UUID) async { await stop(attemptID: attemptID, terminalState: .cancelled, detail: "Cancelled by owner.") }

    public func cancel(runID: UUID) async {
        guard let run = runs[runID] else { return }
        for agent in run.agents where !agent.state.isTerminal { if let id = agent.attempts.last?.id { await cancel(attemptID: id) } }
    }

    public func retry(failedAttemptID: UUID) async throws -> AgentAttempt {
        guard !shuttingDown else { throw JBenchCoreError.storage("JBench is shutting down and cannot retry a lane.") }
        guard let location = locate(failedAttemptID), var run = runs[location.runID], let old = run.agents[location.agentIndex].attempts.last, old.state == .failed || old.state == .timedOut else {
            throw JBenchCoreError.storage("Only failed or timed-out attempts can be retried.")
        }
        let agent = run.agents[location.agentIndex]
        let attempt = AgentAttempt(agentRunID: agent.id, number: agent.attempts.count + 1, requested: agent.requested)
        let capability: ReadOnlyCapability?
        if run.executionMode == .readOnly {
            guard let adapter = adapters[attempt.requested.harness] else { throw JBenchCoreError.storage("No local adapter is configured.") }
            capability = await adapter.readOnlyCapability(for: attempt.requested)
            guard capability!.mayStartReadOnlyRun else { throw JBenchCoreError.storage("Retry blocked: \(capability!.explanation)") }
        } else { capability = nil }

        // `prepare` is also the required retry revalidation point. It must use the recorded
        // run commit, not current HEAD, and returns a unique worktree for editable attempts.
        let result = try await preparation.prepare(.init(runID: run.id, attemptID: attempt.id, attemptNumber: attempt.number, originalDirectoryPath: run.directoryPath, sourceCommit: run.sourceCommit, executionMode: run.executionMode, configuration: attempt.requested, isRetry: true))
        var preparedAttempt = attempt
        applyLifecycle(result.lifecycle, to: &preparedAttempt)
        preparations[preparedAttempt.id] = result
        let snapshot = AttemptLifecycleSnapshot(attemptID: preparedAttempt.id, readOnlyCapability: capability, metadata: result.lifecycle)
        lifecycles[preparedAttempt.id] = snapshot
        run.agents[location.agentIndex].attempts.append(preparedAttempt)
        run.endedAt = nil
        finishedRuns.remove(run.id)
        runs[run.id] = run
        try await persist(run)
        do {
            if let record = snapshot.metadata.worktree { try await history.saveWorktree(record) }
        } catch {
            preparations[preparedAttempt.id] = nil; lifecycles[preparedAttempt.id] = nil
            _ = await preparation.abandon(result)
            run.agents[location.agentIndex].attempts.removeLast()
            runs[run.id] = run
            try? await persist(run)
            throw error
        }
        emit(.lifecycleChanged(snapshot))
        await begin(runID: run.id, agentRunID: agent.id, attemptID: preparedAttempt.id)
        return preparedAttempt
    }

    public func reply(_ reply: ApprovalReply, attemptID: UUID) async throws {
        guard let location = locate(attemptID), let run = runs[location.runID] else { throw JBenchCoreError.missingAttempt(attemptID) }
        let attempt = run.agents[location.agentIndex].attempts[location.attemptIndex]
        guard attempt.state == .waitingForApproval, let adapter = adapters[attempt.requested.harness], let request = pendingApprovals[attemptID] else { throw JBenchCoreError.unsupportedApproval }
        try await adapter.reply(reply, to: request, attemptID: attemptID)
        pendingApprovals[attemptID] = nil
        try await updateAttempt(attemptID: attemptID, to: .running)
    }

    /// Used by application termination. It marks every active attempt interrupted before
    /// waiting, so no late stream event can overwrite the persisted terminal state.
    public func shutdown() async -> RunShutdownReport {
        shuttingDown = true
        let active: [UUID] = runs.values.flatMap { run in
            run.agents.compactMap { agent -> UUID? in
                guard !agent.state.isTerminal else { return nil }
                return agent.attempts.last?.id
            }
        }
        var diagnostics: [RunShutdownDiagnostic] = []
        var runIDs = Set<UUID>()
        for attemptID in active {
            guard let location = locate(attemptID), let before = attempt(attemptID) else { continue }
            runIDs.insert(location.runID)
            let result = await stop(attemptID: attemptID, terminalState: .interrupted, detail: "Interrupted during full app shutdown.") ?? .completed
            let persisted = attempt(attemptID) ?? before
            diagnostics.append(.init(attemptID: attemptID, harness: before.requested.harness, protocolShutdownCompleted: result.completedGracefully, detail: result.detail, ownership: persisted.ownership))
            if !result.completedGracefully { emit(.diagnostic("Shutdown incomplete for attempt \(attemptID.uuidString): \(result.detail ?? "No harness detail was supplied.")")) }
        }
        for attemptID in active { await waitForConsumer(attemptID: attemptID) }
        return RunShutdownReport(diagnostics: diagnostics, interruptedRunIDs: runIDs.sorted { $0.uuidString < $1.uuidString })
    }

    private func begin(runID: UUID, agentRunID: UUID, attemptID: UUID) async {
        guard !shuttingDown, let location = locate(attemptID), let existingRun = runs[location.runID], let adapter = adapters[existingRun.agents[location.agentIndex].requested.harness], let preparationResult = preparations[attemptID] else {
            await stop(attemptID: attemptID, terminalState: .failed, detail: "No prepared local adapter is configured for this harness.")
            return
        }
        do { try await updateAttempt(attemptID: attemptID, to: .starting) } catch { emit(.diagnostic(error.localizedDescription)); return }
        guard let run = runs[runID], let current = attempt(attemptID) else { return }
        let request = HarnessRequest(runID: runID, attemptID: attemptID, prompt: run.prompt, directoryPath: preparationResult.directoryPath, executionMode: run.executionMode, configuration: current.requested)
        let task = Task<Void, Never> { [weak self, adapter] in if let self { await self.consume(adapter: adapter, request: request, agentRunID: agentRunID) } }
        tasks[attemptID] = task
        if let timeout = current.requested.timeoutSeconds {
            timeoutTasks[attemptID] = Task<Void, Never> { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                await self.stop(attemptID: attemptID, terminalState: .timedOut, detail: "Timed out after \(Int(timeout)) seconds.")
            }
        }
    }

    private func consume(adapter: any HarnessAdapter, request: HarnessRequest, agentRunID: UUID) async {
        do {
            for try await event in await adapter.events(for: request) {
                await handle(event, runID: request.runID, agentRunID: agentRunID, attemptID: request.attemptID)
            }
            if let current = attempt(request.attemptID), !current.state.isTerminal {
                await stop(attemptID: request.attemptID, terminalState: .interrupted, detail: "Harness stream ended without a terminal event.")
            }
        } catch is CancellationError {
            // The owner already persisted a terminal state.
        } catch {
            await stop(attemptID: request.attemptID, terminalState: .failed, detail: error.localizedDescription)
        }
        tasks[request.attemptID] = nil
    }

    private func handle(_ event: AdapterEvent, runID: UUID, agentRunID: UUID, attemptID: UUID) async {
        guard let initial = attempt(attemptID), !initial.state.isTerminal else { return }
        do {
            let rawFile = try await evidence.append(.init(attemptID: attemptID, eventType: event.kind.rawValue, rawJSON: event.rawJSON), runID: runID)
            guard var current = attempt(attemptID), !current.state.isTerminal else { return }
            current.rawEventFile = rawFile
            try await replace(current, runID: runID, agentRunID: agentRunID)
        } catch { emit(.diagnostic("Could not retain raw evidence: \(error.localizedDescription)")) }

        guard var current = attempt(attemptID), !current.state.isTerminal else { return }
        switch event.kind {
        case .started:
            if requiresSentinel(attemptID), lifecycleVerification(attemptID)?.succeeded != true {
                await stop(attemptID: attemptID, terminalState: .failed, detail: "Read-only sentinel did not verify before harness execution.")
            } else { try? await updateAttempt(attemptID: attemptID, to: .running) }
        case .outputDelta:
            current.finalResponse += event.text ?? ""
            try? await replace(current, runID: runID, agentRunID: agentRunID)
        case .activity: break
        case .observedSettings:
            current.observed = event.observed ?? current.observed
            try? await replace(current, runID: runID, agentRunID: agentRunID)
        case .metrics:
            current.metrics = event.metrics ?? current.metrics
            try? await replace(current, runID: runID, agentRunID: agentRunID)
        case .lifecycle:
            applyLifecycle(event.lifecycle ?? .init(), to: &current)
            var snapshot = lifecycles[attemptID] ?? .init(attemptID: attemptID)
            snapshot.metadata = merged(snapshot.metadata, event.lifecycle ?? .init())
            lifecycles[attemptID] = snapshot
            try? await replace(current, runID: runID, agentRunID: agentRunID)
            if let record = snapshot.metadata.worktree {
                do { try await history.saveWorktree(record) }
                catch { emit(.diagnostic("Could not persist worktree metadata: \(error.localizedDescription)")) }
            }
            emit(.lifecycleChanged(snapshot))
        case .readOnlyVerification:
            let verification = event.readOnlyVerification ?? .init(succeeded: false, detail: "Adapter supplied no sentinel result.")
            var snapshot = lifecycles[attemptID] ?? .init(attemptID: attemptID)
            snapshot.readOnlyVerification = verification
            lifecycles[attemptID] = snapshot
            emit(.lifecycleChanged(snapshot))
            if !verification.succeeded { await stop(attemptID: attemptID, terminalState: .failed, detail: "Read-only sentinel failed: \(verification.detail)") }
        case .approvalRequest:
            try? await updateAttempt(attemptID: attemptID, to: .waitingForApproval)
            if let request = event.approval { pendingApprovals[attemptID] = request; emit(.approvalNeeded(runID: runID, agentRunID: agentRunID, attemptID: attemptID, request: request)) }
        case .completed:
            if let text = event.text { current.finalResponse += text; try? await replace(current, runID: runID, agentRunID: agentRunID) }
            await stop(attemptID: attemptID, terminalState: .completed, detail: nil)
        case .failed:
            await stop(attemptID: attemptID, terminalState: .failed, detail: event.text ?? "Harness reported a failure.")
        }
    }

    /// A terminal state means the adapter has completed its owned-process shutdown.
    /// Worktree resolution relies on this ordering and must never race a live lane.
    @discardableResult
    private func stop(attemptID: UUID, terminalState: AgentRunState, detail: String?) async -> HarnessShutdownResult? {
        guard !stoppingAttempts.contains(attemptID), var updated = attempt(attemptID), !updated.state.isTerminal,
              let location = locate(attemptID), let run = runs[location.runID] else { return nil }
        stoppingAttempts.insert(attemptID)
        defer { stoppingAttempts.remove(attemptID) }
        timeoutTasks[attemptID]?.cancel(); timeoutTasks[attemptID] = nil; pendingApprovals[attemptID] = nil
        let shutdownResult = if let adapter = adapters[updated.requested.harness] {
            await adapter.shutdown(attemptID: attemptID)
        } else {
            HarnessShutdownResult.completed
        }
        tasks[attemptID]?.cancel(); tasks[attemptID] = nil
        updated.state = terminalState; updated.endedAt = .now
        if terminalState == .failed || terminalState == .timedOut { updated.errorMessage = detail }
        if terminalState == .cancelled || terminalState == .interrupted { updated.cancellationDetail = detail }
        if let started = updated.startedAt, let ended = updated.endedAt { updated.metrics.elapsedSeconds = ended.timeIntervalSince(started); updated.metrics.elapsedProvenance = .locallyMeasured }
        try? await replace(updated, runID: run.id, agentRunID: run.agents[location.agentIndex].id)
        return shutdownResult
    }

    private func updateAttempt(attemptID: UUID, to state: AgentRunState) async throws {
        guard var changed = attempt(attemptID) else { throw JBenchCoreError.missingAttempt(attemptID) }
        guard canTransition(from: changed.state, to: state) else { throw JBenchCoreError.invalidStateTransition(from: changed.state, to: state) }
        changed.state = state
        if state == .starting { changed.startedAt = .now }
        guard let location = locate(attemptID), let run = runs[location.runID] else { return }
        try await replace(changed, runID: run.id, agentRunID: run.agents[location.agentIndex].id)
    }

    private func replace(_ attempt: AgentAttempt, runID: UUID, agentRunID: UUID) async throws {
        guard let location = locate(attempt.id), var run = runs[location.runID] else { return }
        run.agents[location.agentIndex].attempts[location.attemptIndex] = attempt
        if run.agents.allSatisfy({ $0.state.isTerminal }) && run.endedAt == nil { run.endedAt = .now }
        runs[runID] = run
        try await persist(run)
        emit(.attemptChanged(runID: runID, agentRunID: agentRunID, attempt: attempt))
        if run.endedAt != nil, finishedRuns.insert(runID).inserted { emit(.runFinished(run)) }
    }

    private func persist(_ run: BenchmarkRun) async throws { try await history.saveRun(run) }

    private func applyLifecycle(_ metadata: AttemptLifecycleMetadata, to attempt: inout AgentAttempt) {
        if let ownership = metadata.ownership { attempt.ownership = ownership }
        if let session = metadata.protocolSessionID { attempt.protocolSessionID = session }
    }
    private func merged(_ lhs: AttemptLifecycleMetadata, _ rhs: AttemptLifecycleMetadata) -> AttemptLifecycleMetadata {
        .init(ownership: rhs.ownership ?? lhs.ownership, protocolSessionID: rhs.protocolSessionID ?? lhs.protocolSessionID, worktree: rhs.worktree ?? lhs.worktree)
    }
    private func requiresSentinel(_ attemptID: UUID) -> Bool { lifecycles[attemptID]?.readOnlyCapability?.requiresSentinel == true }
    private func lifecycleVerification(_ attemptID: UUID) -> ReadOnlyVerification? { lifecycles[attemptID]?.readOnlyVerification }
    private func attempt(_ id: UUID) -> AgentAttempt? {
        guard let location = locate(id), let run = runs[location.runID] else { return nil }
        return run.agents[location.agentIndex].attempts[location.attemptIndex]
    }
    private func locate(_ attemptID: UUID) -> (runID: UUID, agentIndex: Int, attemptIndex: Int)? {
        for (runID, run) in runs {
            for (agentIndex, agent) in run.agents.enumerated() {
                if let attemptIndex = agent.attempts.firstIndex(where: { $0.id == attemptID }) { return (runID, agentIndex, attemptIndex) }
            }
        }
        return nil
    }
    private func waitForConsumer(attemptID: UUID) async { if let task = tasks[attemptID] { await task.value } }
    private func addSubscriber(_ continuation: AsyncStream<RunUpdate>.Continuation, token: UUID) { subscribers[token] = continuation }
    private func removeSubscriber(_ token: UUID) { subscribers[token] = nil }
    private func emit(_ update: RunUpdate) { subscribers.values.forEach { $0.yield(update) } }
}

public struct FakeHarnessPlan: Sendable, Hashable {
    public var events: [AdapterEvent]
    public var eventDelay: Duration
    public init(events: [AdapterEvent], eventDelay: Duration = .milliseconds(1)) { self.events = events; self.eventDelay = eventDelay }
    public static func successful(response: String) -> Self { .init(events: [.init(kind: .started), .init(kind: .outputDelta, text: response), .init(kind: .completed)]) }
}

public actor FakeHarnessAdapter: HarnessAdapter {
    public nonisolated let kind: HarnessKind = .fake
    public nonisolated let supportsVerifiedReadOnly = true
    private let plans: [String: FakeHarnessPlan]
    private var cancelled: Set<UUID> = []
    public init(plans: [String: FakeHarnessPlan] = [:]) { self.plans = plans }
    public func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        let plan = plans[request.configuration.model] ?? .successful(response: "Fake response for \(request.prompt)")
        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                for event in plan.events {
                    try? await Task.sleep(for: plan.eventDelay)
                    guard !(await self?.cancelled.contains(request.attemptID) ?? true) else { continuation.finish(throwing: CancellationError()); return }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
    public func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {}
    public func cancel(attemptID: UUID) async { cancelled.insert(attemptID) }
}
