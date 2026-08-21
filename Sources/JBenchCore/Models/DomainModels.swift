import Foundation

public enum HarnessKind: String, Codable, CaseIterable, Sendable, Hashable {
    case codex
    case openCode
    case agy
    case fake
}

public enum AvailabilityState: String, Codable, Sendable, Hashable {
    case available, unavailable, customNotVerified, stale
}

public enum AuthenticationStatus: String, Codable, Sendable, Hashable {
    case ready, missing, unknown
}

public struct HarnessInstallation: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var harness: HarnessKind
    public var executablePath: String
    public var version: String?
    public var authenticationStatus: AuthenticationStatus
    public var diagnosticMessage: String?
    public var lastSuccessfulDiscoveryAt: Date?

    public init(id: UUID = UUID(), harness: HarnessKind, executablePath: String, version: String? = nil, authenticationStatus: AuthenticationStatus = .unknown, diagnosticMessage: String? = nil, lastSuccessfulDiscoveryAt: Date? = nil) {
        self.id = id; self.harness = harness; self.executablePath = executablePath; self.version = version
        self.authenticationStatus = authenticationStatus; self.diagnosticMessage = diagnosticMessage; self.lastSuccessfulDiscoveryAt = lastSuccessfulDiscoveryAt
    }
}

public struct ModelCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var harness: HarnessKind
    public var nativeModelID: String
    public var displayName: String?
    public var nativeReasoningValues: [String]
    public var discoverySource: String
    public var catalogedAt: Date
    public var availability: AvailabilityState

    public init(id: UUID = UUID(), harness: HarnessKind, nativeModelID: String, displayName: String? = nil, nativeReasoningValues: [String] = [], discoverySource: String, catalogedAt: Date = .now, availability: AvailabilityState = .available) {
        self.id = id; self.harness = harness; self.nativeModelID = nativeModelID; self.displayName = displayName
        self.nativeReasoningValues = nativeReasoningValues; self.discoverySource = discoverySource; self.catalogedAt = catalogedAt; self.availability = availability
    }
}

public enum ApprovalPolicy: String, Codable, CaseIterable, Sendable, Hashable {
    case askEveryTime, allowForAttempt, denyAll
}

public struct AgentConfiguration: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var harness: HarnessKind
    public var model: String
    public var reasoning: String?
    /// `nil` means the owner explicitly selected No Timeout.
    public var timeoutSeconds: TimeInterval?
    public var approvalPolicy: ApprovalPolicy

    public init(id: UUID = UUID(), harness: HarnessKind, model: String, reasoning: String? = nil, timeoutSeconds: TimeInterval? = 30 * 60, approvalPolicy: ApprovalPolicy = .askEveryTime) {
        self.id = id; self.harness = harness; self.model = model; self.reasoning = reasoning; self.timeoutSeconds = timeoutSeconds; self.approvalPolicy = approvalPolicy
    }
}

public struct JudgeConfiguration: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var harness: HarnessKind
    public var model: String
    public var reasoning: String?
    public var steeringPrompt: String?
    public init(id: UUID = UUID(), name: String, harness: HarnessKind, model: String, reasoning: String? = nil, steeringPrompt: String? = nil) {
        self.id = id; self.name = name; self.harness = harness; self.model = model; self.reasoning = reasoning; self.steeringPrompt = steeringPrompt
    }
}

public struct JudgeVote: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var runID: UUID
    public var judge: JudgeConfiguration
    public var winningAgentRunID: UUID?
    public var winningBlindLabel: String?
    public var reasoning: String?
    public var errorMessage: String?
    public var rawEvidenceFile: String?
    public var recordedAt: Date
    public init(id: UUID = UUID(), runID: UUID, judge: JudgeConfiguration, winningAgentRunID: UUID? = nil, winningBlindLabel: String? = nil, reasoning: String? = nil, errorMessage: String? = nil, rawEvidenceFile: String? = nil, recordedAt: Date = .now) {
        self.id = id; self.runID = runID; self.judge = judge; self.winningAgentRunID = winningAgentRunID; self.winningBlindLabel = winningBlindLabel; self.reasoning = reasoning; self.errorMessage = errorMessage; self.rawEvidenceFile = rawEvidenceFile; self.recordedAt = recordedAt
    }
}

public struct Preset: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var agents: [AgentConfiguration]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, agents: [AgentConfiguration], createdAt: Date = .now, updatedAt: Date = .now) throws {
        try Self.validate(agents)
        self.id = id; self.name = name; self.agents = agents; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public static func validate(_ agents: [AgentConfiguration]) throws {
        guard (2...6).contains(agents.count) else { throw JBenchCoreError.invalidAgentCount(agents.count) }
    }
}

public enum RepositoryState: String, Codable, Sendable, Hashable { case cleanGit, dirtyGit, nonGit, missing }
public enum ExecutionMode: String, Codable, Sendable, Hashable { case readOnly, editable }

public enum AgentRunState: String, Codable, CaseIterable, Sendable, Hashable {
    case queued, starting, running, waitingForApproval, completed, failed, cancelled, timedOut, interrupted
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .timedOut, .interrupted].contains(self) }
}

public enum AggregateRunState: String, Codable, Sendable, Hashable { case queued, running, waitingForApproval, completed, partiallyCompleted, failed, cancelled, interrupted }

public enum MetricProvenance: String, Codable, Sendable, Hashable { case harnessReported, locallyMeasured, unavailable }

public struct ObservedValue: Codable, Sendable, Hashable {
    public var value: String?
    public var provenance: MetricProvenance
    public init(_ value: String? = nil, provenance: MetricProvenance = .unavailable) { self.value = value; self.provenance = provenance }
    public static let unavailable = ObservedValue()
}

public struct AttemptMetrics: Codable, Sendable, Hashable {
    public var elapsedSeconds: Double?
    public var elapsedProvenance: MetricProvenance
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var tokenProvenance: MetricProvenance
    public var cost: Decimal?
    public var costProvenance: MetricProvenance
    public init(elapsedSeconds: Double? = nil, elapsedProvenance: MetricProvenance = .unavailable, inputTokens: Int? = nil, outputTokens: Int? = nil, tokenProvenance: MetricProvenance = .unavailable, cost: Decimal? = nil, costProvenance: MetricProvenance = .unavailable) {
        self.elapsedSeconds = elapsedSeconds; self.elapsedProvenance = elapsedProvenance; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.tokenProvenance = tokenProvenance; self.cost = cost; self.costProvenance = costProvenance
    }
    public static let unavailable = AttemptMetrics()
}

public struct ObservedSettings: Codable, Sendable, Hashable {
    public var model: ObservedValue
    public var reasoning: ObservedValue
    public var harnessVersion: ObservedValue
    public init(model: ObservedValue = .unavailable, reasoning: ObservedValue = .unavailable, harnessVersion: ObservedValue = .unavailable) { self.model = model; self.reasoning = reasoning; self.harnessVersion = harnessVersion }
}

public struct ProcessOwnership: Codable, Sendable, Hashable {
    public var processID: Int32?
    public var processIdentity: String
    public var serverProcessID: Int32?
    public var serverIdentity: String
    public init(processID: Int32? = nil, processIdentity: String = "", serverProcessID: Int32? = nil, serverIdentity: String = "") { self.processID = processID; self.processIdentity = processIdentity; self.serverProcessID = serverProcessID; self.serverIdentity = serverIdentity }
}

public enum WorktreeDisposition: String, Codable, Sendable, Hashable { case pending, kept, transferred, discarded }

public struct WorktreeRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var attemptID: UUID
    public var originalRepositoryPath: String
    public var sourceCommit: String
    public var ownedWorktreePath: String
    public var changedFileCount: Int?
    public var patchReference: String?
    public var disposition: WorktreeDisposition
    public var transferredPath: String?
    public var cleanupVerified: Bool?
    public init(id: UUID = UUID(), attemptID: UUID, originalRepositoryPath: String, sourceCommit: String, ownedWorktreePath: String, changedFileCount: Int? = nil, patchReference: String? = nil, disposition: WorktreeDisposition = .pending, transferredPath: String? = nil, cleanupVerified: Bool? = nil) {
        self.id = id; self.attemptID = attemptID; self.originalRepositoryPath = originalRepositoryPath; self.sourceCommit = sourceCommit; self.ownedWorktreePath = ownedWorktreePath; self.changedFileCount = changedFileCount; self.patchReference = patchReference; self.disposition = disposition; self.transferredPath = transferredPath; self.cleanupVerified = cleanupVerified
    }
}

/// A normalized display event from a harness. The complete native event remains in
/// `EvidenceStore`; attempts retain only their most recent display activity.
public struct AttemptActivity: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var text: String

    public init(timestamp: Date = .now, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public struct AgentAttempt: Codable, Sendable, Hashable, Identifiable {
    /// Keeps persistence bounded while retaining enough recent context for the lane.
    public static let maximumRetainedActivityEntries = 100

    public let id: UUID
    public var agentRunID: UUID
    public var number: Int
    public var state: AgentRunState
    public var requested: AgentConfiguration
    public var observed: ObservedSettings
    public var metrics: AttemptMetrics
    public var ownership: ProcessOwnership
    public var protocolSessionID: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var finalResponse: String
    public var errorMessage: String?
    public var cancellationDetail: String?
    public var rawEventFile: String?
    /// A rolling normalized activity trail. Older entries are evicted after 100;
    /// the full raw stream is retained separately in `EvidenceStore`.
    public private(set) var activity: [AttemptActivity]

    public init(id: UUID = UUID(), agentRunID: UUID, number: Int, state: AgentRunState = .queued, requested: AgentConfiguration, observed: ObservedSettings = .init(), metrics: AttemptMetrics = .unavailable, ownership: ProcessOwnership = .init(), protocolSessionID: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil, finalResponse: String = "", errorMessage: String? = nil, cancellationDetail: String? = nil, rawEventFile: String? = nil, activity: [AttemptActivity] = []) {
        self.id = id; self.agentRunID = agentRunID; self.number = number; self.state = state; self.requested = requested; self.observed = observed; self.metrics = metrics; self.ownership = ownership; self.protocolSessionID = protocolSessionID; self.startedAt = startedAt; self.endedAt = endedAt; self.finalResponse = finalResponse; self.errorMessage = errorMessage; self.cancellationDetail = cancellationDetail; self.rawEventFile = rawEventFile; self.activity = Array(activity.suffix(Self.maximumRetainedActivityEntries))
    }

    public mutating func appendActivity(_ text: String, timestamp: Date = .now) {
        activity.append(.init(timestamp: timestamp, text: text))
        if activity.count > Self.maximumRetainedActivityEntries {
            activity.removeFirst(activity.count - Self.maximumRetainedActivityEntries)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentRunID, number, state, requested, observed, metrics, ownership, protocolSessionID, startedAt, endedAt, finalResponse, errorMessage, cancellationDetail, rawEventFile, activity
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            agentRunID: try values.decode(UUID.self, forKey: .agentRunID),
            number: try values.decode(Int.self, forKey: .number),
            state: try values.decode(AgentRunState.self, forKey: .state),
            requested: try values.decode(AgentConfiguration.self, forKey: .requested),
            observed: try values.decode(ObservedSettings.self, forKey: .observed),
            metrics: try values.decode(AttemptMetrics.self, forKey: .metrics),
            ownership: try values.decode(ProcessOwnership.self, forKey: .ownership),
            protocolSessionID: try values.decodeIfPresent(String.self, forKey: .protocolSessionID),
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt),
            endedAt: try values.decodeIfPresent(Date.self, forKey: .endedAt),
            finalResponse: try values.decode(String.self, forKey: .finalResponse),
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            cancellationDetail: try values.decodeIfPresent(String.self, forKey: .cancellationDetail),
            rawEventFile: try values.decodeIfPresent(String.self, forKey: .rawEventFile),
            activity: try values.decodeIfPresent([AttemptActivity].self, forKey: .activity) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(agentRunID, forKey: .agentRunID); try values.encode(number, forKey: .number); try values.encode(state, forKey: .state); try values.encode(requested, forKey: .requested); try values.encode(observed, forKey: .observed); try values.encode(metrics, forKey: .metrics); try values.encode(ownership, forKey: .ownership); try values.encodeIfPresent(protocolSessionID, forKey: .protocolSessionID); try values.encodeIfPresent(startedAt, forKey: .startedAt); try values.encodeIfPresent(endedAt, forKey: .endedAt); try values.encode(finalResponse, forKey: .finalResponse); try values.encodeIfPresent(errorMessage, forKey: .errorMessage); try values.encodeIfPresent(cancellationDetail, forKey: .cancellationDetail); try values.encodeIfPresent(rawEventFile, forKey: .rawEventFile); try values.encode(activity, forKey: .activity)
    }
}

public struct AgentRun: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var runID: UUID
    public var displayOrder: Int
    public var blindReviewOrder: Int?
    public var requested: AgentConfiguration
    public var attempts: [AgentAttempt]
    public init(id: UUID = UUID(), runID: UUID, displayOrder: Int, blindReviewOrder: Int? = nil, requested: AgentConfiguration, attempts: [AgentAttempt] = []) { self.id = id; self.runID = runID; self.displayOrder = displayOrder; self.blindReviewOrder = blindReviewOrder; self.requested = requested; self.attempts = attempts }
    public var state: AgentRunState { attempts.last?.state ?? .queued }
}

public struct Verdict: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var runID: UUID
    public var winningAgentRunID: UUID?
    public var note: String?
    public var recordedAt: Date
    public init(id: UUID = UUID(), runID: UUID, winningAgentRunID: UUID? = nil, note: String? = nil, recordedAt: Date = .now) { self.id = id; self.runID = runID; self.winningAgentRunID = winningAgentRunID; self.note = note; self.recordedAt = recordedAt }
}

public struct BenchmarkRun: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var prompt: String
    public var directoryPath: String
    public var repositoryState: RepositoryState
    public var sourceCommit: String?
    public var executionMode: ExecutionMode
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var rawEvidenceDirectory: String
    public var harnessVersions: [HarnessKind: String]
    public var integrationProtocolVersions: [HarnessKind: String]?
    public var agents: [AgentRun]
    public var judgeConfigurations: [JudgeConfiguration]
    public var judgeVotes: [JudgeVote]
    public init(id: UUID = UUID(), title: String? = nil, prompt: String, directoryPath: String, repositoryState: RepositoryState, sourceCommit: String? = nil, executionMode: ExecutionMode, createdAt: Date = .now, startedAt: Date? = nil, endedAt: Date? = nil, rawEvidenceDirectory: String, harnessVersions: [HarnessKind: String] = [:], integrationProtocolVersions: [HarnessKind: String]? = nil, agents: [AgentRun], judgeConfigurations: [JudgeConfiguration] = [], judgeVotes: [JudgeVote] = []) throws {
        try Preset.validate(agents.map(\.requested)); self.id = id; self.title = title ?? Self.title(for: prompt); self.prompt = prompt; self.directoryPath = directoryPath; self.repositoryState = repositoryState; self.sourceCommit = sourceCommit; self.executionMode = executionMode; self.createdAt = createdAt; self.startedAt = startedAt; self.endedAt = endedAt; self.rawEvidenceDirectory = rawEvidenceDirectory; self.harnessVersions = harnessVersions; self.integrationProtocolVersions = integrationProtocolVersions; self.agents = agents; self.judgeConfigurations = judgeConfigurations; self.judgeVotes = judgeVotes
    }
    private enum CodingKeys: String, CodingKey { case id, title, prompt, directoryPath, repositoryState, sourceCommit, executionMode, createdAt, startedAt, endedAt, rawEvidenceDirectory, harnessVersions, integrationProtocolVersions, agents, judgeConfigurations, judgeVotes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), title: c.decodeIfPresent(String.self, forKey: .title), prompt: c.decode(String.self, forKey: .prompt), directoryPath: c.decode(String.self, forKey: .directoryPath), repositoryState: c.decode(RepositoryState.self, forKey: .repositoryState), sourceCommit: c.decodeIfPresent(String.self, forKey: .sourceCommit), executionMode: c.decode(ExecutionMode.self, forKey: .executionMode), createdAt: c.decode(Date.self, forKey: .createdAt), startedAt: c.decodeIfPresent(Date.self, forKey: .startedAt), endedAt: c.decodeIfPresent(Date.self, forKey: .endedAt), rawEvidenceDirectory: c.decode(String.self, forKey: .rawEvidenceDirectory), harnessVersions: c.decodeIfPresent([HarnessKind: String].self, forKey: .harnessVersions) ?? [:], integrationProtocolVersions: c.decodeIfPresent([HarnessKind: String].self, forKey: .integrationProtocolVersions), agents: c.decode([AgentRun].self, forKey: .agents), judgeConfigurations: c.decodeIfPresent([JudgeConfiguration].self, forKey: .judgeConfigurations) ?? [], judgeVotes: c.decodeIfPresent([JudgeVote].self, forKey: .judgeVotes) ?? [])
    }
    public var state: AggregateRunState {
        let states = agents.map(\.state)
        if states.allSatisfy({ $0 == .queued }) { return .queued }
        if states.contains(.waitingForApproval) { return .waitingForApproval }
        if states.contains(where: { !$0.isTerminal }) { return .running }
        if states.allSatisfy({ $0 == .completed }) { return .completed }
        if states.allSatisfy({ $0 == .failed }) { return .failed }
        if states.allSatisfy({ $0 == .cancelled }) { return .cancelled }
        if states.allSatisfy({ $0 == .interrupted }) { return .interrupted }
        return .partiallyCompleted
    }
    public static func title(for prompt: String, limit: Int = 72) -> String {
        let normalized = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > limit else { return normalized.isEmpty ? "Untitled Run" : normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }
}

public enum JBenchCoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidAgentCount(Int), invalidStateTransition(from: AgentRunState, to: AgentRunState), missingAttempt(UUID), unsupportedApproval, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidAgentCount(let count): "Select two to six agents, not \(count)."
        case .invalidStateTransition(let from, let to): "Cannot move an attempt from \(from.rawValue) to \(to.rawValue)."
        case .missingAttempt(let id): "Attempt \(id) was not found."
        case .unsupportedApproval: "This harness does not support that approval response."
        case .storage(let message): message
        }
    }
}

public func canTransition(from: AgentRunState, to: AgentRunState) -> Bool {
    switch (from, to) {
    case (_, _) where from.isTerminal: return false
    case (.queued, .starting), (.queued, .cancelled), (.queued, .interrupted), (.starting, .running), (.starting, .failed), (.starting, .cancelled), (.starting, .timedOut), (.running, .waitingForApproval), (.running, .completed), (.running, .failed), (.running, .cancelled), (.running, .timedOut), (.running, .interrupted), (.waitingForApproval, .running), (.waitingForApproval, .failed), (.waitingForApproval, .cancelled), (.waitingForApproval, .timedOut), (.waitingForApproval, .interrupted): return true
    default: return false
    }
}
