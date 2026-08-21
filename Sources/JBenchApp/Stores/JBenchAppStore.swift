import AppKit
import Darwin
import Foundation
import Observation
import UserNotifications
import JBenchCore

/// Main-window state and the app's only composition root. The default path uses
/// the locally discovered Codex/OpenCode executables. Fake lanes are available
/// only through the explicit provider-free demo action.
@Observable @MainActor
final class JBenchAppStore: JBenchRunService {
    var appearance: AppAppearance {
        didSet {
            applyAppearanceToApplication()
            if persistsAppearance { Self.saveAppearance(appearance) }
        }
    }
    var section: AppSection = .newRun {
        didSet { resetVerdictSelectionForCurrentTarget() }
    }
    var prompt = ""
    var runTitle = ""
    var directory: String
    var executionMode: ExecutionMode = .readOnly {
        didSet {
            if executionMode == .editable && repositorySnapshot.state != .cleanGit {
                executionMode = .readOnly
                statusMessage = repositoryExplanation
            }
        }
    }
    var configurations: [AgentConfiguration] = [
        .init(harness: .codex, model: "Not selected"),
        .init(harness: .codex, model: "Not selected")
    ]
    var judgeConfigurations: [JudgeConfiguration] = []
    var judgeVotes: [JudgeVote] = []
    var isJudgingActive = false
    var judgeStatusMessage: String?
    var lanes: [LanePresentation] = []
    var reviewMode: RunPresentation = .sideBySide
    var isRevealOn = false
    var hidesReviewIdentities: Bool {
        reviewMode == .blindReview && !isRevealOn
    }
    var winningLaneID: UUID?
    var reviewNote = ""
    var history: [HistoryPresentation] = []
    var selectedHistoryID: UUID? {
        didSet {
            if section == .history {
                resetVerdictSelectionForCurrentTarget()
            }
        }
    }
    var presets: [Preset] = []
    var timeoutMinutes = 30 { didSet { updateTimeouts() } }
    var usesNoTimeout = false { didSet { updateTimeouts() } }
    var notifyOnCompletion = false
    var diagnostics: [HarnessDiagnostic] = []
    var statusMessage = "Discovering local harnesses…"
    var isBackgroundRunActive = false
    var worktreeMessage: String?
    var isDemoMode = false
    var discoverySettings: DiscoverySettings
    var customCodexModel = ""
    var customOpenCodeModel = ""
    var customAgyModel = ""
    var repositorySnapshot: RepositorySnapshot
    var deletionPreview: HistoryDeletionPreview?
    var isShowingDeletionConfirmation = false
    var deleteAllPreviews: [HistoryDeletionPreview] = []
    var isShowingDeleteAllConfirmation = false
    var isShowingExportWarning = false
    var isShowingRawEvidence = false
    var rawEvidenceTitle = "Raw events"
    var rawEvidenceText = ""
    var pendingRunAgain: BenchmarkRun?
    var isShowingRunAgainConfirmation = false
    var historyTitleRename = ""
    var historyTitleRunID: UUID?
    var isShowingHistoryTitleRename = false

    private let applicationSupport: URL
    private let persistsAppearance: Bool
    private let historyStore: SQLiteHistoryStore?
    private let evidenceStore: EvidenceStore?
    private let repository = RepositoryService()
    private let worktrees: EditableWorktreeService?
    private let preparation: (any AttemptPreparationService)?
    private let exportService = ExportService()
    private var discovery: DiscoveryService
    private var coordinator: RunCoordinator?
    private var judgeEngine: JudgeEngine?
    private var judgeTask: Task<Void, Never>?
    private var judgeTaskToken: UUID?
    private var updateTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeRun: BenchmarkRun?
    private var automaticJudgingRunIDs = Set<UUID>()
    private var historyRuns: [UUID: BenchmarkRun] = [:]
    private var worktreeRecords: [UUID: WorktreeRecord] = [:]
    private var worktreeDiffs: [UUID: String] = [:]
    private var attemptIDsByLane: [UUID: UUID] = [:]
    private var pendingApprovalsByAttemptID: [UUID: ApprovalRequest] = [:]
    private var verdicts: [UUID: Verdict] = [:]
    private var pendingExportRunID: UUID?
    private var pendingExportDestination: URL?
    private var pendingExportIsBundle = false
    private let configurationPolicy = RunConfigurationPolicy()

    private struct EvidenceBundlePatchSources {
        var urls: [URL]
        var generatedTemporaryURLs: [URL]
    }

    init(automaticallyRunsDemo: Bool = true, appearanceOverride: AppAppearance? = nil) {
        persistsAppearance = appearanceOverride == nil
        appearance = appearanceOverride ?? Self.loadAppearance()
        directory = FileManager.default.currentDirectoryPath
        repositorySnapshot = RepositorySnapshot(state: .missing, inspectedDirectory: FileManager.default.currentDirectoryPath)
        let supportDirectory = Self.applicationSupportDirectory()
        let initialSettings = Self.loadDiscoverySettings()
        applicationSupport = supportDirectory
        discoverySettings = initialSettings

        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let history = try SQLiteHistoryStore(databaseURL: supportDirectory.appending(path: "History.sqlite"))
            let evidence = try EvidenceStore(rootDirectory: supportDirectory.appending(path: "Evidence", directoryHint: .isDirectory))
            let editableWorktrees = try EditableWorktreeService(repository: repository, ownedRoot: supportDirectory.appending(path: "Worktrees", directoryHint: .isDirectory))
            historyStore = history
            evidenceStore = evidence
            worktrees = editableWorktrees
            preparation = RepositoryAttemptPreparationService(repository: repository, worktrees: editableWorktrees)
        } catch {
            historyStore = nil
            evidenceStore = nil
            worktrees = nil
            preparation = nil
            statusMessage = "Local storage is unavailable: \(error.localizedDescription)"
        }

        discovery = Self.makeDiscovery(settings: initialSettings, cacheURL: supportDirectory.appending(path: "model-catalog.json"))
        rebuildCoordinator()
        applyAppearanceToApplication()
        Task {
            await loadPersistedState()
            await refreshRepository()
            if CommandLine.arguments.contains("--provider-free-demo") {
                loadProviderFreeDemo()
                if automaticallyRunsDemo {
                    await startRun(prompt: prompt, directory: directory, mode: executionMode, configurations: configurations)
                }
            } else {
                await refreshDiscovery()
            }
        }
    }

    var canRun: Bool {
        configurationPolicy.canRun(
            prompt: prompt,
            configurations: configurations,
            isDemoMode: isDemoMode,
            isBackgroundRunActive: isBackgroundRunActive,
            settings: discoverySettings
        )
    }

    var selectedHistory: HistoryPresentation? { history.first(where: { $0.id == selectedHistoryID }) }
    func hasVerdict(for runID: UUID) -> Bool { verdicts[runID] != nil }
    /// The persisted verdict for the run currently shown in the review workspace.
    var currentVerdict: Verdict? {
        guard let targetID = verdictTargetID else { return nil }
        return verdicts[targetID]
    }
    /// Whether the visible selection differs from the persisted verdict.
    var hasPendingVerdictSelection: Bool {
        guard let winningLaneID else { return false }
        return winningLaneID != currentVerdict?.winningAgentRunID
    }

    func isDraftWinnerSelection(for laneID: UUID) -> Bool {
        hasPendingVerdictSelection && winningLaneID == laneID
    }

    func isPersistedWinner(for laneID: UUID) -> Bool {
        !hasPendingVerdictSelection && currentVerdict?.winningAgentRunID == laneID
    }
    var canUseEditable: Bool { repositorySnapshot.state == .cleanGit }
    var repositoryExplanation: String {
        switch repositorySnapshot.state {
        case .cleanGit: return "Clean Git repository at \(repositorySnapshot.repositoryRoot ?? repositorySnapshot.inspectedDirectory)."
        case .dirtyGit: return "This Git working tree has changes. Use read-only, or commit/stash changes before editable lanes."
        case .nonGit: return "This directory is not a Git repository. Use read-only lanes."
        case .missing: return "This directory does not exist. Choose an existing directory, then use read-only or clean Git editable lanes."
        }
    }
    var menuBarIcon: String {
        if lanes.contains(where: { $0.state == .waitingForApproval }) { return "hand.raised.circle.fill" }
        if isBackgroundRunActive { return "bolt.circle.fill" }
        return "checkmark.circle"
    }
    var menuBarLabel: String {
        if lanes.contains(where: { $0.state == .waitingForApproval }) { return "Approval needed" }
        if isBackgroundRunActive { return "Lanes running" }
        return "Idle"
    }

    func catalog(for harness: HarnessKind) -> [ModelCatalogEntry] {
        configurationPolicy.catalog(for: harness, settings: discoverySettings)
    }

    func models(for harness: HarnessKind) -> [String] {
        configurationPolicy.models(for: harness, settings: discoverySettings)
    }

    func reasoningValues(for configuration: AgentConfiguration) -> [String] {
        configurationPolicy.reasoningValues(for: configuration, settings: discoverySettings)
    }

    func reasoningValues(for judge: JudgeConfiguration) -> [String] {
        reasoningValues(for: AgentConfiguration(harness: judge.harness, model: judge.model))
    }

    func addJudge() {
        let harness: HarnessKind = isDemoMode ? .fake : .codex
        let model = isDemoMode ? "Provider-free judge" : models(for: harness).first ?? "Not selected"
        judgeConfigurations.append(.init(name: "Judge \(judgeConfigurations.count + 1)", harness: harness, model: model))
        statusMessage = "Added judge \(judgeConfigurations.count)"
    }

    func removeJudge(_ id: UUID) { judgeConfigurations.removeAll { $0.id == id } }

    func normalizeJudge(_ id: UUID) {
        guard let index = judgeConfigurations.firstIndex(where: { $0.id == id }) else { return }
        let judge = judgeConfigurations[index]
        if judge.harness == .openCode { return }
        let available = models(for: judge.harness)
        if judge.harness != .fake, !available.contains(judge.model) {
            judgeConfigurations[index].model = available.first ?? "Not selected"
        }
    }

    var canRerunJudges: Bool {
        guard let run = activeRun, run.endedAt != nil else { return false }
        return !judgeConfigurations.isEmpty && run.agents.filter({ $0.state == .completed && !($0.attempts.last?.finalResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }).count >= 2
    }

    var judgeActionTitle: String { judgeVotes.isEmpty ? "Run Judges" : "Run Again" }

    func judgeVoteDisplay(_ vote: JudgeVote) -> String {
        let label = vote.winningBlindLabel ?? "No winner"
        guard !hidesReviewIdentities,
              let winningID = vote.winningAgentRunID,
              let agent = activeRun?.agents.first(where: { $0.id == winningID }) else { return label }
        return "\(label) · \(agent.requested.harness.rawValue) / \(agent.requested.model)"
    }

    func rerunJudges() {
        guard canRerunJudges, var run = activeRun, let coordinator else {
            statusMessage = "Judges need a completed run with at least two responses."
            return
        }
        run.judgeConfigurations = judgeConfigurations
        run.judgeVotes = []
        activeRun = run
        judgeVotes = []
        lanes = presentation(for: run)
        judgeTask?.cancel()
        let token = UUID()
        judgeTaskToken = token
        judgeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearJudgeTaskIfOwned(token) }
            do {
                let canonical = try await coordinator.updateJudgeResults(runID: run.id, configurations: run.judgeConfigurations, votes: [])
                guard !Task.isCancelled else { return }
                await self.runJudges(for: canonical)
            } catch {
                guard !Task.isCancelled else { return }
                self.judgeStatusMessage = "Could not save judge changes: \(self.actionable(error))"
            }
        }
    }

    func addConfiguration() {
        guard configurations.count < 6 else { return }
        let harness: HarnessKind = isDemoMode ? .fake : .codex
        let model = isDemoMode ? "Provider-free sample" : models(for: harness).first ?? "Not selected"
        configurations.append(.init(harness: harness, model: model, timeoutSeconds: configurationPolicy.timeoutSeconds(timeoutMinutes: timeoutMinutes, usesNoTimeout: usesNoTimeout)))
        statusMessage = "Added lane \(configurations.count)"
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Directory"
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
            statusMessage = "Working directory selected"
            Task { await refreshRepository() }
        }
    }

    func removeConfiguration(_ id: UUID) {
        guard configurations.count > 2 else { return }
        configurations.removeAll { $0.id == id }
    }

    func normalizeConfiguration(_ id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index] = configurationPolicy.normalized(configurations[index], settings: discoverySettings)
    }

    func start(prompt: String, directory: String, mode: ExecutionMode, configurations: [AgentConfiguration]) {
        guard canRun else {
            statusMessage = isDemoMode ? "Choose two provider-free demo lanes and enter a prompt." : "Select discovered native models for every lane before running."
            return
        }
        Task { await startRun(prompt: prompt, directory: directory, mode: mode, configurations: configurations) }
    }

    private func startRun(prompt: String, directory: String, mode: ExecutionMode, configurations: [AgentConfiguration]) async {
        guard let coordinator else { statusMessage = "JBench could not open its local database. Restart after fixing Application Support permissions."; return }
        do {
            let snapshot = try await repository.inspect(directory: URL(filePath: directory))
            let sourceCommit: String?
            if mode == .editable {
                let context = try await repository.prepareEditableRun(directory: URL(filePath: directory))
                sourceCommit = context.sourceCommit
            } else {
                sourceCommit = snapshot.headCommit
            }
            let versions = Dictionary(uniqueKeysWithValues: diagnostics.compactMap { diagnostic in
                diagnostic.version == "Version unavailable" ? nil : (diagnostic.harness, diagnostic.version)
            })
            let protocols: [HarnessKind: String] = [
                .codex: "app-server JSON-RPC contract v1",
                .openCode: "HTTP/SSE v1.18.18 envelope contract",
                .agy: "CLI stream-json protocol v1.1",
                .fake: "provider-free fixture contract v1"
            ]
            let draft = RunDraft(title: runTitle.nilIfEmpty, prompt: prompt, directoryPath: directory, repositoryState: snapshot.state, sourceCommit: sourceCommit, executionMode: mode, harnessVersions: versions, integrationProtocolVersions: protocols, configurations: configurations, judgeConfigurations: judgeConfigurations)
            statusMessage = isDemoMode ? "Running provider-free demo lanes" : "Starting \(configurations.count) local harness lanes"
            let run = try await coordinator.start(draft)
            activeRunID = run.id
            activeRun = run
            lanes = presentation(for: run)
            isBackgroundRunActive = true
            section = .newRun
        } catch {
            statusMessage = actionable(error)
        }
    }

    func cancel(laneID: UUID) {
        guard let run = runContainingLane(laneID),
              let agent = run.agents.first(where: { $0.id == laneID }), let attempt = agent.attempts.last else { return }
        Task { await coordinator?.cancel(attemptID: attempt.id) }
    }

    func retry(laneID: UUID) {
        guard !isBackgroundRunActive else {
            statusMessage = "Wait for the active lanes to finish before retrying another lane."
            return
        }
        guard let run = runContainingLane(laneID), let agent = run.agents.first(where: { $0.id == laneID }), let attempt = agent.attempts.last else { return }
        guard let coordinator else {
            statusMessage = "JBench could not open its local database."
            return
        }
        let previousRun = activeRun
        let previousRunID = activeRunID
        let previousLanes = lanes
        let wasBackgroundRunActive = isBackgroundRunActive
        isBackgroundRunActive = true
        Task {
            do {
                guard let refreshed = try await coordinator.run(id: run.id) else {
                    activeRun = previousRun
                    activeRunID = previousRunID
                    lanes = previousLanes
                    isBackgroundRunActive = wasBackgroundRunActive
                    statusMessage = "Could not load this run for retry."
                    return
                }
                activeRunID = refreshed.id
                activeRun = refreshed
                lanes = presentation(for: refreshed)
                _ = try await coordinator.retry(failedAttemptID: attempt.id)
            }
            catch {
                activeRun = previousRun
                activeRunID = previousRunID
                lanes = previousLanes
                isBackgroundRunActive = wasBackgroundRunActive
                statusMessage = actionable(error)
            }
        }
    }

    func reply(_ reply: ApprovalReply, laneID: UUID) {
        guard let run = runContainingLane(laneID), let agent = run.agents.first(where: { $0.id == laneID }), let attempt = agent.attempts.last else { return }
        Task {
            do {
                try await coordinator?.reply(reply, attemptID: attempt.id)
                pendingApprovalsByAttemptID[attempt.id] = nil
            }
            catch { statusMessage = actionable(error) }
        }
    }

    func savePreset() {
        let name = "Custom \(presets.count + 1)"
        Task {
            do {
                let preset = try Preset(name: name, agents: configurations)
                try await historyStore?.savePreset(preset)
                presets.insert(preset, at: 0)
                statusMessage = "Saved \(name)"
            } catch { statusMessage = actionable(error) }
        }
    }

    func applyPreset(_ preset: Preset) {
        configurations = preset.agents
        isDemoMode = configurations.allSatisfy { $0.harness == .fake }
        section = .newRun
        statusMessage = "Loaded \(preset.name)"
    }

    func deletePreset(_ preset: Preset) {
        Task {
            do { try await historyStore?.deletePreset(id: preset.id); presets.removeAll { $0.id == preset.id }; statusMessage = "Deleted \(preset.name)" }
            catch { statusMessage = actionable(error) }
        }
    }

    func renamePreset(_ preset: Preset, to name: String) {
        Task {
            do {
                let renamed = try Preset(id: preset.id, name: name, agents: preset.agents, createdAt: preset.createdAt)
                try await historyStore?.savePreset(renamed)
                if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = renamed }
                statusMessage = "Renamed preset to \(renamed.name)"
            } catch { statusMessage = actionable(error) }
        }
    }

    func replacePreset(_ preset: Preset) {
        Task {
            do {
                let updated = try Preset(id: preset.id, name: preset.name, agents: configurations, createdAt: preset.createdAt)
                try await historyStore?.savePreset(updated)
                if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = updated }
                statusMessage = "Updated \(preset.name)"
            } catch { statusMessage = actionable(error) }
        }
    }

    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        let now = Date()
        Task {
            for index in presets.indices {
                presets[index].updatedAt = now.addingTimeInterval(-Double(index))
                try? await historyStore?.savePreset(presets[index])
            }
            statusMessage = "Reordered presets"
        }
    }

    func movePreset(_ preset: Preset, by offset: Int) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let destination = index + offset
        guard presets.indices.contains(destination) else { return }
        presets.swapAt(index, destination)
        let now = Date()
        Task {
            for index in presets.indices {
                presets[index].updatedAt = now.addingTimeInterval(-Double(index))
                try? await historyStore?.savePreset(presets[index])
            }
            statusMessage = "Reordered presets"
        }
    }

    func loadProviderFreeDemo() {
        isDemoMode = true
        configurations = [
            .init(harness: .fake, model: "Provider-free sample", reasoning: "Deterministic", timeoutSeconds: 30),
            .init(harness: .fake, model: "Provider-free alternate", reasoning: "Deterministic", timeoutSeconds: 30)
        ]
        judgeConfigurations = [
            .init(name: "Correctness", harness: .fake, model: "Provider-free judge", reasoning: "Deterministic", steeringPrompt: "Focus on correctness and choose the candidate with the most accurate response.")
        ]
        judgeVotes = []
        prompt = prompt.isEmpty ? "Summarize the operational risks in this change." : prompt
        statusMessage = "Demo mode uses no provider, account, or harness prompt."
    }

    func refreshRepository() async {
        do {
            repositorySnapshot = try await repository.inspect(directory: URL(filePath: directory))
            if executionMode == .editable && !canUseEditable { executionMode = .readOnly; statusMessage = repositoryExplanation }
        } catch {
            repositorySnapshot = RepositorySnapshot(state: .missing, inspectedDirectory: directory)
            statusMessage = actionable(error)
        }
    }

    func leaveDemoMode() {
        isDemoMode = false
        configurations = (0..<2).map { _ in .init(harness: .codex, model: models(for: .codex).first ?? "Not selected", timeoutSeconds: configurationPolicy.timeoutSeconds(timeoutMinutes: timeoutMinutes, usesNoTimeout: usesNoTimeout)) }
        statusMessage = "Normal mode uses discovered local harnesses."
    }

    func saveManualVerdict() {
        guard let winningLaneID else { statusMessage = "Select a winner first"; return }
        let targetID = verdictTargetID
        let selectedWinnerID = winningLaneID
        guard let targetID else { statusMessage = "No run is selected for this verdict."; return }
        Task {
            do {
                guard let run = try await coordinator?.run(id: targetID) ?? historyRuns[targetID] else { statusMessage = "Could not load the selected run."; return }
                guard verdictTargetID == targetID else { return }
                guard run.agents.contains(where: { $0.id == selectedWinnerID }) else {
                    self.winningLaneID = nil
                    statusMessage = "Select a winner from the run you are reviewing."
                    return
                }
                let verdict = Verdict(runID: run.id, winningAgentRunID: selectedWinnerID, note: reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                try await historyStore?.saveVerdict(verdict)
                verdicts[run.id] = verdict
                isRevealOn = true
                await loadHistory()
                statusMessage = "Manual verdict saved"
            } catch { statusMessage = actionable(error) }
        }
    }

    var canRevealIdentities: Bool {
        let targetID = verdictTargetID
        guard let targetID else { return false }
        return verdicts[targetID] != nil
    }

    func skipManualVerdict() {
        let targetID = verdictTargetID
        guard let targetID else { statusMessage = "No run is selected."; return }
        Task {
            do {
                let note = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                let verdict = Verdict(runID: targetID, winningAgentRunID: nil, note: note)
                try await historyStore?.saveVerdict(verdict)
                verdicts[targetID] = verdict
                winningLaneID = nil
                isRevealOn = true
                await loadHistory()
                statusMessage = "Verdict skipped. Identities revealed."
            } catch { statusMessage = actionable(error) }
        }
    }

    func viewActiveRunInHistory() {
        if let activeRunID {
            selectedHistoryID = activeRunID
            loadVerdictForSelectedHistory()
        }
        section = .history
    }

    func startNewRun() {
        guard !isBackgroundRunActive else {
            statusMessage = "Wait for the active run to finish before starting a new run."
            return
        }
        activeRunID = nil
        judgeTask?.cancel()
        judgeTask = nil
        judgeTaskToken = nil
        isJudgingActive = false
        activeRun = nil
        lanes = []
        judgeVotes = []
        judgeStatusMessage = nil
        isRevealOn = false
        winningLaneID = nil
        reviewNote = ""
        section = .newRun
    }

    func loadVerdictForSelectedHistory() {
        guard let id = selectedHistoryID else { return }
        let verdict = verdicts[id]
        winningLaneID = verdict?.winningAgentRunID.flatMap { laneID in
            historyRuns[id]?.agents.contains(where: { $0.id == laneID }) == true ? laneID : nil
        }
        reviewNote = verdict?.note ?? ""
    }

    func prepareHistoryDeletion(_ runID: UUID) {
        Task {
            do {
                guard let preview = try await historyStore?.deletionPreview(for: runID) else { statusMessage = "This history record no longer exists."; return }
                guard preview.canDelete else { statusMessage = preview.refusalReason ?? "Resolve pending worktrees before deleting history."; return }
                deletionPreview = preview
                isShowingDeletionConfirmation = true
            } catch { statusMessage = actionable(error) }
        }
    }

    var deletionImpact: String {
        guard let preview = deletionPreview else { return "" }
        let worktrees = preview.worktrees.map { "\($0.disposition.rawValue): \($0.ownedWorktreePath)" }.joined(separator: "\n")
        return "Record: \(preview.title)\nEvidence files: \(preview.evidenceFiles.count)\nWorktrees:\n\(worktrees.isEmpty ? "None" : worktrees)\nTransferred worktrees are never deleted."
    }

    var deleteAllImpact: String {
        let evidenceCount = deleteAllPreviews.reduce(0) { $0 + $1.evidenceFiles.count }
        let transferredCount = deleteAllPreviews.reduce(0) { $0 + $1.transferredWorktrees.count }
        return "Records: \(deleteAllPreviews.count)\nEvidence files: \(evidenceCount)\nTransferred worktrees preserved: \(transferredCount)\nPending worktrees block this action."
    }

    func prepareDeleteAllHistory() {
        Task {
            do {
                let previews = try await historyStore?.deletionPreviews() ?? []
                guard !previews.isEmpty else { statusMessage = "History is already empty."; return }
                if let blocked = previews.first(where: { !$0.canDelete }) {
                    statusMessage = blocked.refusalReason ?? "Resolve pending worktrees before deleting history."
                    return
                }
                deleteAllPreviews = previews
                isShowingDeleteAllConfirmation = true
            } catch { statusMessage = actionable(error) }
        }
    }

    func confirmDeleteAllHistory(deleteEvidence: Bool) {
        let ids = Set(deleteAllPreviews.map(\.runID))
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await historyStore?.deleteAll(confirmation: .init(runIDs: ids, deleteEvidence: deleteEvidence), evidenceStore: evidenceStore)
                history.removeAll { ids.contains($0.id) }
                for id in ids { verdicts[id] = nil; historyRuns[id] = nil }
                selectedHistoryID = history.first?.id
                deleteAllPreviews = []
                statusMessage = deleteEvidence ? "Deleted all history records and evidence." : "Deleted all history records. Evidence remains on disk."
            } catch { statusMessage = actionable(error) }
        }
    }

    func confirmHistoryDeletion(deleteEvidence: Bool) {
        guard let preview = deletionPreview else { return }
        Task {
            do {
                try await historyStore?.deleteRun(id: preview.runID, confirmation: .init(runIDs: [preview.runID], deleteEvidence: deleteEvidence), evidenceStore: evidenceStore)
                history.removeAll { $0.id == preview.runID }
                selectedHistoryID = history.first?.id
                verdicts[preview.runID] = nil
                deletionPreview = nil
                statusMessage = deleteEvidence ? "Deleted local history record and evidence." : "Deleted local history record. Evidence remains on disk."
            } catch { statusMessage = actionable(error) }
        }
    }

    func prepareRenameHistoryTitle(_ item: HistoryPresentation) {
        historyTitleRunID = item.id
        historyTitleRename = item.title
        isShowingHistoryTitleRename = true
    }

    func renameHistoryTitle() {
        guard let id = historyTitleRunID else { return }
        let title = historyTitleRename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { statusMessage = "Run title cannot be empty."; return }
        Task {
            do {
                guard var run = try await historyStore?.run(id: id) else { statusMessage = "This history record no longer exists."; return }
                run.title = title
                try await historyStore?.saveRun(run)
                if activeRun?.id == id { activeRun = run; refreshActiveLanes() }
                await loadHistory()
                statusMessage = "Renamed history run."
            } catch { statusMessage = actionable(error) }
        }
    }

    func runAgain(_ item: HistoryPresentation) {
        Task {
            do {
                guard let prior = try await historyStore?.run(id: item.id) else { statusMessage = "Could not load the selected history record."; return }
                let current = try await repository.inspect(directory: URL(filePath: prior.directoryPath))
                guard prior.executionMode == .editable else { applyRunAgain(prior, repository: current); return }
                guard current.state == .cleanGit else {
                    applyRunAgain(prior, repository: current, forceReadOnly: true)
                    statusMessage = "The original directory is no longer clean Git. Loaded the run as read-only."
                    return
                }
                if current.headCommit != prior.sourceCommit {
                    pendingRunAgain = prior
                    repositorySnapshot = current
                    isShowingRunAgainConfirmation = true
                    return
                }
                applyRunAgain(prior, repository: current)
            } catch { statusMessage = actionable(error) }
        }
    }

    func confirmRunAgainWithCurrentCommit() {
        guard let run = pendingRunAgain else { return }
        pendingRunAgain = nil
        applyRunAgain(run, repository: repositorySnapshot)
        statusMessage = "Loaded prior run. Editable mode will record the current clean HEAD when you start."
    }

    private func applyRunAgain(_ run: BenchmarkRun, repository: RepositorySnapshot, forceReadOnly: Bool = false) {
        prompt = run.prompt
        runTitle = run.title
        directory = run.directoryPath
        repositorySnapshot = repository
        executionMode = forceReadOnly ? .readOnly : run.executionMode
        configurations = run.agents.sorted { $0.displayOrder < $1.displayOrder }.map(\.requested)
        judgeConfigurations = run.judgeConfigurations
        judgeVotes = run.judgeVotes
        isDemoMode = configurations.allSatisfy { $0.harness == .fake }
        section = .newRun
    }

    func exportMarkdown(for item: HistoryPresentation? = nil) { export(item: item, bundle: false) }
    func exportEvidenceBundle(for item: HistoryPresentation? = nil) { export(item: item, bundle: true) }
    func exportMarkdown(runID: UUID?) { export(targetID: runID, bundle: false) }
    func exportEvidenceBundle(runID: UUID?) { export(targetID: runID, bundle: true) }

    private func export(item: HistoryPresentation?, bundle: Bool) {
        export(targetID: item?.id, bundle: bundle)
    }

    private func export(targetID: UUID?, bundle: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = bundle ? "Export Bundle" : "Export Report"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        pendingExportRunID = targetID ?? activeRun?.id
        pendingExportDestination = destination
        pendingExportIsBundle = bundle
        isShowingExportWarning = true
    }

    func confirmExport() {
        guard let targetID = pendingExportRunID, let destination = pendingExportDestination else { return }
        let bundle = pendingExportIsBundle
        pendingExportRunID = nil
        pendingExportDestination = nil
        Task {
            do {
                guard let run = try await coordinator?.run(id: targetID) else { statusMessage = "No run is available to export."; return }
                let verdict = try await historyStore?.verdict(for: run.id)
                if bundle {
                    let patchSources = try await evidenceBundlePatchSources(for: run)
                    defer { patchSources.generatedTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
                    let result = try exportService.exportEvidenceBundle(run, verdict: verdict, patches: patchSources.urls, to: destination)
                    statusMessage = "Evidence bundle saved to \(result.directory.lastPathComponent)"
                } else {
                    let result = try exportService.exportMarkdownReport(run, verdict: verdict, to: destination)
                    statusMessage = "Markdown report saved to \(result.lastPathComponent)"
                }
            } catch { statusMessage = actionable(error) }
        }
    }

    func showRawEvidence(for laneID: UUID) {
        guard let attemptID = attemptIDsByLane[laneID] else { statusMessage = "No attempt evidence is mapped to this lane."; return }
        let runID = activeRun?.agents.contains(where: { $0.id == laneID }) == true
            ? activeRun?.id
            : historyRuns.values.first(where: { $0.agents.contains(where: { $0.id == laneID }) })?.id
        guard let runID else { statusMessage = "No run evidence is mapped to this lane."; return }
        Task {
            do {
                let records = try await evidenceStore?.records(runID: runID, attemptID: attemptID) ?? []
                rawEvidenceTitle = "Raw events · \(records.count)"
                rawEvidenceText = records.map { "[\($0.timestamp.formatted(.iso8601))] \($0.eventType)\n\($0.rawJSON)" }.joined(separator: "\n\n")
                if rawEvidenceText.isEmpty { rawEvidenceText = "No raw events were recorded for this attempt." }
                isShowingRawEvidence = true
            } catch { statusMessage = actionable(error) }
        }
    }

    var runAgainCommitMessage: String {
        let prior = pendingRunAgain?.sourceCommit ?? "Unavailable"
        let current = repositorySnapshot.headCommit ?? "Unavailable"
        return "Prior source commit: \(prior)\nCurrent clean HEAD: \(current)\nThe new run will use the current commit after you confirm."
    }

    func worktreeAction(_ action: String, lane: LanePresentation) {
        guard let attemptID = attemptIDsByLane[lane.id],
              let record = worktreeRecords.values.first(where: { $0.attemptID == attemptID }) else {
            worktreeMessage = "No JBench-owned worktree is recorded for this lane."
            return
        }
        if action == "Keep" || action == "Discard" || action == "Export patch" {
            guard let attempt = attempt(for: lane.id), attempt.state.isTerminal else {
                worktreeMessage = "Patch export, Keep, and Discard are blocked until this lane is terminal and its owned process has exited."
                return
            }
            if ownedProcessIsStillRunning(attempt) {
                worktreeMessage = "Patch export, Keep, and Discard are blocked while JBench still owns a running harness process."
                return
            }
        }
        switch action {
        case "Open":
            let path = record.transferredPath ?? record.ownedWorktreePath
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            worktreeMessage = "Opened \(path)"
        case "Export patch": exportPatch(record)
        case "Keep": keepWorktree(record)
        case "Discard": discardWorktree(record)
        default: break
        }
    }

    func canTransferWorktree(for laneID: UUID) -> Bool {
        guard let attempt = attempt(for: laneID), attempt.state.isTerminal else { return false }
        return !ownedProcessIsStillRunning(attempt)
    }

    private func exportPatch(_ record: WorktreeRecord) {
        guard let attempt = attemptByID(record.attemptID), attempt.state.isTerminal, !ownedProcessIsStillRunning(attempt) else {
            worktreeMessage = "Patch export is blocked until this lane is terminal and its owned process has exited."
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "JBench-\(record.attemptID.uuidString.prefix(8)).patch"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                guard let current = attemptByID(record.attemptID), current.state.isTerminal, !ownedProcessIsStillRunning(current) else {
                    worktreeMessage = "Patch export is blocked until this lane is terminal and its owned process has exited."
                    return
                }
                let result = try await worktrees?.exportPatch(for: record.id, to: destination)
                if var updated = worktreeRecords[record.id] { updated.patchReference = result?.path; worktreeRecords[record.id] = updated; try await historyStore?.saveWorktree(updated); refreshActiveLanes() }
                worktreeMessage = "Patch exported to \(destination.lastPathComponent)"
            } catch { worktreeMessage = actionable(error) }
        }
    }

    private func keepWorktree(_ record: WorktreeRecord) {
        guard let attempt = attemptByID(record.attemptID) else { worktreeMessage = "The matching terminal attempt could not be loaded."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Choose Parent Folder"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appending(path: "JBench-\(record.attemptID.uuidString.prefix(8))", directoryHint: .isDirectory)
        Task {
            do {
                try await worktrees?.authorizeResolution(record.id, after: attempt)
                guard let updated = try await worktrees?.keep(record.id, at: destination) else { return }
                worktreeRecords[updated.id] = updated; try await historyStore?.saveWorktree(updated); refreshActiveLanes()
                worktreeMessage = "Worktree transferred to \(destination.path)"
            } catch { worktreeMessage = actionable(error) }
        }
    }

    private func discardWorktree(_ record: WorktreeRecord) {
        guard let attempt = attemptByID(record.attemptID) else { worktreeMessage = "The matching terminal attempt could not be loaded."; return }
        Task {
            do {
                try await worktrees?.authorizeResolution(record.id, after: attempt)
                guard let updated = try await worktrees?.discard(record.id) else { return }
                worktreeRecords[updated.id] = updated; try await historyStore?.saveWorktree(updated); refreshActiveLanes()
                worktreeMessage = "Discarded JBench-owned worktree."
            } catch { worktreeMessage = actionable(error) }
        }
    }

    func refreshDiscovery() async {
        guard !isBackgroundRunActive else { statusMessage = "Discovery waits until active lanes finish."; return }
        statusMessage = "Refreshing local harness discovery…"
        diagnostics = await discovery.discover()
            .map { HarnessDiagnostic(id: UUID(), harness: $0.harness, path: $0.executablePath, version: $0.version ?? "Version unavailable", status: $0.authenticationStatus, discovery: $0.diagnosticMessage ?? "Native models discovered") }
        discoverySettings = await discovery.settings
        Self.saveDiscoverySettings(discoverySettings)
        rebuildCoordinator()
        normalizeAllConfigurations()
        let ready = diagnostics.filter { $0.status == .ready }.count
        statusMessage = ready > 0 ? "Discovered \(ready) local harness\(ready == 1 ? "" : "es")." : "No ready local harness was found. Add an executable override in Settings."
    }

    func updateExecutableOverride(_ path: String, for harness: HarnessKind) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { discoverySettings.executableOverrides[harness] = nil } else { discoverySettings.executableOverrides[harness] = value }
        Self.saveDiscoverySettings(discoverySettings)
        discovery = Self.makeDiscovery(settings: discoverySettings, cacheURL: applicationSupport.appending(path: "model-catalog.json"))
        Task { await refreshDiscovery() }
    }

    func addCustomModel(for harness: HarnessKind) {
        let textValue: String = switch harness {
        case .codex: customCodexModel
        case .openCode: customOpenCodeModel
        case .agy: customAgyModel
        case .fake: ""
        }
        let value = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { statusMessage = "Enter the harness-native model ID first."; return }
        guard !catalog(for: harness).contains(where: { $0.nativeModelID == value }) else { statusMessage = "That model is already listed."; return }
        discoverySettings.customModels.append(.init(harness: harness, nativeModelID: value, discoverySource: "Owner custom fallback", availability: .customNotVerified))
        Self.saveDiscoverySettings(discoverySettings)
        let settings = discoverySettings
        let harnessName: String = switch harness {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .agy: "Antigravity"
        case .fake: "Demo"
        }
        Task {
            try? await discovery.updateSettings(settings)
            statusMessage = "Added custom \(harnessName) model. It remains unverified until a run observes it."
        }
        switch harness {
        case .codex: customCodexModel = ""
        case .openCode: customOpenCodeModel = ""
        case .agy: customAgyModel = ""
        case .fake: break
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notifyOnCompletion = enabled
        guard enabled else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func shutdownForTermination() async -> String {
        updateTask?.cancel()
        let task = judgeTask
        task?.cancel()
        judgeTask = nil
        judgeTaskToken = nil
        if let task { await task.value }
        guard let coordinator else {
            statusMessage = "Shutdown complete: no active local coordinator."
            return statusMessage
        }
        let report = await coordinator.shutdown()
        let incomplete = report.diagnostics.filter { !$0.protocolShutdownCompleted }
        statusMessage = incomplete.isEmpty
            ? "Shutdown complete: \(report.diagnostics.count) owned lane process\(report.diagnostics.count == 1 ? "" : "es") stopped."
            : "Shutdown complete with \(incomplete.count) incomplete owned-process diagnostic\(incomplete.count == 1 ? "" : "s")."
        return statusMessage
    }

    private func rebuildCoordinator() {
        guard let historyStore, let evidenceStore else { return }
        let resolver = ExecutableResolver()
        var adapters: [any HarnessAdapter] = [FakeHarnessAdapter(plans: [
            "Provider-free sample": .successful(response: "Provider-free demo output. No local Codex or OpenCode prompt was run."),
            "Provider-free judge": .successful(response: #"{"winner":"B","reason":"Deterministic demo judge selected Candidate B."}"#),
            "Provider-free alternate": .successful(response: "Second provider-free demo output for comparison. No account or provider was used.")
        ])]
        if let codex = resolver.resolve(harness: .codex, override: discoverySettings.executableOverrides[.codex]) {
            adapters.append(CodexAppServerAdapter(executableURL: codex.url))
        }
        if let openCode = resolver.resolve(harness: .openCode, override: discoverySettings.executableOverrides[.openCode]) {
            // This remains false until a future version-specific restriction + sentinel diagnostic is implemented.
            adapters.append(OpenCodeAdapter(executablePath: openCode.url.path, supportsVerifiedReadOnly: false))
        }
        if let agy = resolver.resolve(harness: .agy, override: discoverySettings.executableOverrides[.agy]) {
            adapters.append(AgyAdapter(executablePath: agy.url.path))
        }
        coordinator = RunCoordinator(adapters: adapters, history: historyStore, evidence: evidenceStore, preparation: preparation ?? PassthroughAttemptPreparationService())
        judgeEngine = JudgeEngine(adapters: adapters, evidence: evidenceStore)
        subscribeToUpdates()
    }

    private func subscribeToUpdates() {
        updateTask?.cancel()
        guard let coordinator else { return }
        updateTask = Task { [weak self] in
            let stream = await coordinator.updates()
            for await update in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(update, coordinator: coordinator)
            }
        }
    }

    private func receive(_ update: RunUpdate, coordinator: RunCoordinator) async {
        switch update {
        case .runCreated(let run):
            activeRunID = run.id; activeRun = run; judgeVotes = run.judgeVotes; lanes = presentation(for: run)
        case .attemptChanged(let id, _, _):
            if let refreshed = try? await coordinator.run(id: id) {
                reconcilePendingApprovals(for: refreshed)
                await collectTerminalWorktreeChanges(for: refreshed)
                guard activeRunID == id else { return }
                activeRun = refreshed
                judgeVotes = refreshed.judgeVotes
                lanes = presentation(for: refreshed)
                if refreshed.endedAt != nil { await finish(run: refreshed) }
            }
        case .runFinished(let run):
            guard activeRunID == run.id else { return }
            activeRun = run
            judgeVotes = run.judgeVotes
            lanes = presentation(for: run)
            await finish(run: run)
        case .lifecycleChanged(let snapshot):
            if let record = snapshot.metadata.worktree { worktreeRecords[record.id] = record; refreshActiveLanes() }
        case .approvalNeeded(let runID, let agentRunID, let attemptID, let approval):
            guard runID == activeRunID, let index = lanes.firstIndex(where: { $0.id == agentRunID }) else { return }
            pendingApprovalsByAttemptID[attemptID] = approval
            lanes[index].approval = approval
            statusMessage = "Approval needed for lane \((lanes.firstIndex(where: { $0.id == agentRunID }) ?? 0) + 1)"
            if notifyOnCompletion { notifyApproval(approval, lane: index + 1) }
        case .diagnostic(let detail): statusMessage = detail
        }
    }

    private func finish(run: BenchmarkRun) async {
        guard activeRunID == run.id else { return }
        await collectTerminalWorktreeChanges(for: run)
        isBackgroundRunActive = false
        statusMessage = "\(run.agents.count) lanes \(run.state == .completed ? "completed" : "finished with \(run.state.rawValue)")"
        await loadHistory()
        if !run.judgeConfigurations.isEmpty, automaticJudgingRunIDs.insert(run.id).inserted { await launchJudgeTask(for: run) }
        if notifyOnCompletion { notifyCompletion(for: run) }
    }

    private func runJudges(for run: BenchmarkRun) async {
        guard let judgeEngine, let coordinator else { return }
        guard activeRunID == run.id, !Task.isCancelled else { return }
        isJudgingActive = true
        judgeStatusMessage = "Judges are reviewing completed responses…"
        defer {
            if activeRunID == run.id { isJudgingActive = false }
        }
        do {
            let votes = await judgeEngine.judge(run: run)
            guard activeRunID == run.id, !Task.isCancelled else { return }
            let judged = try await coordinator.updateJudgeResults(runID: run.id, configurations: run.judgeConfigurations, votes: votes)
            guard activeRunID == run.id, !Task.isCancelled else { return }
            activeRun = judged
            judgeVotes = judged.judgeVotes
            lanes = presentation(for: judged)
            historyRuns[judged.id] = judged
            judgeStatusMessage = judged.judgeVotes.contains(where: { $0.errorMessage != nil }) ? "Some judges failed. Review each judge's result." : "All judges finished"
            await loadHistory()
        } catch {
            if activeRunID == run.id, !Task.isCancelled { judgeStatusMessage = "Judging failed: \(actionable(error))" }
        }
    }

    private func launchJudgeTask(for run: BenchmarkRun) async {
        judgeTask?.cancel()
        let token = UUID()
        judgeTaskToken = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runJudges(for: run)
        }
        judgeTask = task
        await task.value
        clearJudgeTaskIfOwned(token)
    }

    private func clearJudgeTaskIfOwned(_ token: UUID) {
        guard judgeTaskToken == token else { return }
        judgeTask = nil
        judgeTaskToken = nil
    }

    private func loadPersistedState() async {
        guard let persistedRuns = try? await historyStore?.search() else { return }
        let runs = await reconcilePersistedNonterminalAttempts(in: persistedRuns)
        await populateHistory(from: runs)
        if let stored = try? await historyStore?.presets() { presets = stored }
    }

    private func loadHistory() async {
        guard let persistedRuns = try? await historyStore?.search() else { return }
        await populateHistory(from: persistedRuns)
    }

    private func populateHistory(from runs: [BenchmarkRun]) async {
        historyRuns = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        for run in runs {
            if let verdict = try? await historyStore?.verdict(for: run.id) { verdicts[run.id] = verdict }
            if let records = try? await historyStore?.worktrees(for: run.id) {
                for record in records {
                    worktreeRecords[record.id] = record
                    guard record.disposition == .pending else { continue }
                    do {
                        try await worktrees?.restore(record)
                        await collectChanges(for: record)
                    } catch {
                        statusMessage = "Worktree restore rejected for \(record.ownedWorktreePath): \(actionable(error))"
                    }
                }
            }
        }
        history = runs.map { run in HistoryPresentation(id: run.id, title: run.title, date: run.createdAt, state: run.state, directory: run.directoryPath, mode: run.executionMode, lanes: presentation(for: run), prompt: run.prompt, judgeConfigurations: run.judgeConfigurations, judgeVotes: run.judgeVotes) }
        if selectedHistoryID == nil { selectedHistoryID = history.first?.id }
        if section == .history {
            loadVerdictForSelectedHistory()
        }
    }

    private func historyRun(id: UUID?) -> BenchmarkRun? {
        guard let id, let item = history.first(where: { $0.id == id }) else { return nil }
        // HistoryPresentation intentionally keeps only display data. Active runs are in memory;
        // actions on older runs are limited to viewing/exporting and therefore do not need a coordinator call.
        return activeRun?.id == item.id ? activeRun : nil
    }

    private var verdictTargetID: UUID? {
        section == .history ? selectedHistoryID : activeRun?.id
    }

    private func resetVerdictSelectionForCurrentTarget() {
        winningLaneID = nil
        reviewNote = ""
        isRevealOn = false
        if section == .history, selectedHistoryID != nil {
            loadVerdictForSelectedHistory()
        } else if section == .newRun, activeRunID != nil {
            loadVerdictForActiveRun()
        }
    }

    func loadVerdictForActiveRun() {
        guard let id = activeRunID, let verdict = verdicts[id] else { return }
        winningLaneID = verdict.winningAgentRunID.flatMap { laneID in
            activeRun?.agents.contains(where: { $0.id == laneID }) == true ? laneID : nil
        }
        reviewNote = verdict.note ?? ""
        isRevealOn = true
    }

    private func runContainingLane(_ laneID: UUID) -> BenchmarkRun? {
        if let activeRun, activeRun.agents.contains(where: { $0.id == laneID }) { return activeRun }
        return historyRuns.values.first(where: { $0.agents.contains(where: { $0.id == laneID }) })
    }

    private func refreshActiveLanes() {
        if let activeRun { lanes = presentation(for: activeRun) }
    }

    private func presentation(for run: BenchmarkRun) -> [LanePresentation] {
        run.agents.sorted { $0.displayOrder < $1.displayOrder }.map { agent in
            let attempt = agent.attempts.last
            if let attempt { attemptIDsByLane[agent.id] = attempt.id }
            let worktree = attempt.flatMap { attempt in worktreeRecords.values.first(where: { $0.attemptID == attempt.id }) }
            return LanePresentation(
                id: agent.id,
                configuration: agent.requested,
                state: agent.state,
                activity: activity(for: attempt),
                output: attempt?.finalResponse ?? "",
                observedModel: attempt?.observed.model.value,
                observedReasoning: attempt?.observed.reasoning.value,
                elapsed: measured(attempt?.metrics.elapsedSeconds, provenance: attempt?.metrics.elapsedProvenance),
                tokens: tokenText(attempt?.metrics),
                cost: costText(attempt?.metrics),
                approval: attempt.flatMap { pendingApprovalsByAttemptID[$0.id] },
                worktree: worktree.map { WorktreePresentation(path: $0.transferredPath ?? $0.ownedWorktreePath, changedFiles: $0.changedFileCount ?? 0, status: $0.disposition.rawValue, diff: worktreeDiffs[$0.id] ?? "") },
                blindReviewOrder: agent.blindReviewOrder ?? agent.displayOrder,
                judgeVotes: run.judgeVotes.filter { $0.winningAgentRunID == agent.id }
            )
        }
    }

    private func collectTerminalWorktreeChanges(for run: BenchmarkRun) async {
        for attempt in run.agents.flatMap(\.attempts) where attempt.state.isTerminal {
            guard let record = worktreeRecords.values.first(where: { $0.attemptID == attempt.id }), record.disposition == .pending else { continue }
            await collectChanges(for: record)
        }
        refreshActiveLanes()
    }

    private func collectChanges(for record: WorktreeRecord) async {
        do {
            guard let changes = try await worktrees?.collectChanges(for: record.id) else { return }
            var updated = record
            updated.changedFileCount = changes.files.count
            worktreeRecords[record.id] = updated
            worktreeDiffs[record.id] = String(decoding: changes.patch, as: UTF8.self)
            try await historyStore?.saveWorktree(updated)
        } catch {
            statusMessage = "Could not inspect worktree changes: \(actionable(error))"
        }
    }

    private func reconcilePendingApprovals(for run: BenchmarkRun) {
        let waitingAttemptIDs = Set(run.agents.compactMap { agent -> UUID? in
            guard let attempt = agent.attempts.last, attempt.state == .waitingForApproval else { return nil }
            return attempt.id
        })
        pendingApprovalsByAttemptID = pendingApprovalsByAttemptID.filter { waitingAttemptIDs.contains($0.key) }
    }

    private func reconcilePersistedNonterminalAttempts(in persistedRuns: [BenchmarkRun]) async -> [BenchmarkRun] {
        var reconciledRuns: [BenchmarkRun] = []
        for var run in persistedRuns {
            if run.id == activeRunID {
                reconciledRuns.append(run)
                continue
            }
            var changed = false
            let now = Date.now
            for agentIndex in run.agents.indices {
                for attemptIndex in run.agents[agentIndex].attempts.indices {
                    var attempt = run.agents[agentIndex].attempts[attemptIndex]
                    guard !attempt.state.isTerminal else { continue }
                    let cleanupDiagnostic = await terminateVerifiedPersistedProcesses(for: attempt)
                    attempt.state = .interrupted
                    attempt.endedAt = now
                    attempt.cancellationDetail = "Interrupted after JBench relaunched; this coordinator cannot resume persisted harness processes. \(cleanupDiagnostic)"
                    attempt.appendActivity("Relaunch cleanup: \(cleanupDiagnostic)", timestamp: now)
                    if let started = attempt.startedAt {
                        attempt.metrics.elapsedSeconds = now.timeIntervalSince(started)
                        attempt.metrics.elapsedProvenance = .locallyMeasured
                    }
                    run.agents[agentIndex].attempts[attemptIndex] = attempt
                    changed = true
                }
            }
            if changed {
                if run.agents.allSatisfy({ $0.state.isTerminal }) { run.endedAt = now }
                do { try await historyStore?.saveRun(run) }
                catch { statusMessage = "Could not mark interrupted lanes after relaunch: \(actionable(error))" }
            }
            reconciledRuns.append(run)
        }
        return reconciledRuns
    }

    private func evidenceBundlePatchSources(for run: BenchmarkRun) async throws -> EvidenceBundlePatchSources {
        let attempts = Dictionary(uniqueKeysWithValues: run.agents.flatMap(\.attempts).map { ($0.id, $0) })
        let terminalRecords = worktreeRecords.values
            .filter { attempts[$0.attemptID]?.state.isTerminal == true }
            .sorted { $0.attemptID.uuidString < $1.attemptID.uuidString }
        var urls = terminalRecords.compactMap { validPatchReferenceURL(for: $0) }
        var generatedTemporaryURLs: [URL] = []
        let pendingRecords = terminalRecords.filter { $0.disposition == .pending }
        do {
            guard pendingRecords.isEmpty || worktrees != nil else {
                throw JBenchCoreError.storage("JBench could not access its owned worktrees.")
            }
            for record in pendingRecords {
                guard let attempt = attempts[record.attemptID], !ownedProcessIsStillRunning(attempt) else {
                    throw JBenchCoreError.storage("Patch export is blocked until this lane's owned process has exited.")
                }
                let patch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("JBench-\(record.attemptID.uuidString)-\(UUID().uuidString).patch")
                let generated = try await worktrees!.exportPatch(for: record.id, to: patch)
                urls.append(generated)
                generatedTemporaryURLs.append(generated)
            }
            return .init(urls: urls, generatedTemporaryURLs: generatedTemporaryURLs)
        } catch {
            generatedTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    private func validPatchReferenceURL(for record: WorktreeRecord) -> URL? {
        guard let reference = record.patchReference, !reference.isEmpty else { return nil }
        let url = URL(fileURLWithPath: reference).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    private func terminateVerifiedPersistedProcesses(for attempt: AgentAttempt) async -> String {
        let owned = attempt.ownership
        var diagnostics: [String] = []
        var processedPIDs = Set<Int32>()
        for (label, pid, serialized) in [("harness", owned.processID, owned.processIdentity), ("server", owned.serverProcessID, owned.serverIdentity)] {
            guard let pid, pid > 0, processedPIDs.insert(pid).inserted else { continue }
            diagnostics.append(await terminateVerifiedPersistedProcess(label: label, pid: pid, serialized: serialized))
        }
        return diagnostics.isEmpty ? "No owned process was recorded." : diagnostics.joined(separator: " ")
    }

    private func terminateVerifiedPersistedProcess(label: String, pid: Int32, serialized: String) async -> String {
        guard !serialized.isEmpty else { return "\(label) process \(pid) was not signaled because its stored identity is unavailable." }
        guard let initial = OwnedProcessService.identity(for: pid) else { return "\(label) process \(pid) has no current identity; no signal was sent." }
        guard initial.serialized == serialized else { return "\(label) process \(pid) identity no longer matches; no signal was sent." }

        let ownsGroup = OwnedProcessLauncher.ownsProcessGroup(pid)
        guard OwnedProcessService.identity(for: pid)?.serialized == serialized else {
            return "\(label) process \(pid) identity became unavailable before cleanup; no signal was sent."
        }
        let sentTermination = ownsGroup
            ? OwnedProcessLauncher.signalGroup(pid, SIGTERM)
            : Darwin.kill(pid, SIGTERM) == 0
        guard sentTermination else { return "\(label) process \(pid) could not be sent SIGTERM after verification." }
        if await verifiedProcessExit(pid: pid, serialized: serialized, ownsGroup: ownsGroup, timeout: .seconds(5)) {
            return "\(label) process \(pid) exited during relaunch cleanup."
        }

        guard OwnedProcessService.identity(for: pid)?.serialized == serialized else {
            return "\(label) process \(pid) did not exit, but its identity could not be reverified; no SIGKILL was sent."
        }
        let sentKill = ownsGroup
            ? OwnedProcessLauncher.signalGroup(pid, SIGKILL)
            : Darwin.kill(pid, SIGKILL) == 0
        guard sentKill else { return "\(label) process \(pid) did not exit and could not be sent SIGKILL after verification." }
        return await verifiedProcessExit(pid: pid, serialized: serialized, ownsGroup: ownsGroup, timeout: .seconds(1))
            ? "\(label) process \(pid) exited after relaunch cleanup fallback."
            : "\(label) process \(pid) cleanup is incomplete after verified SIGKILL."
    }

    private func verifiedProcessExit(pid: Int32, serialized: String, ownsGroup: Bool, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let leaderMatches = OwnedProcessService.identity(for: pid)?.serialized == serialized
            let groupRuns = ownsGroup && OwnedProcessLauncher.groupIsRunning(pid)
            if !leaderMatches && !groupRuns { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return OwnedProcessService.identity(for: pid)?.serialized != serialized
            && (!ownsGroup || !OwnedProcessLauncher.groupIsRunning(pid))
    }

    private func activity(for attempt: AgentAttempt?) -> String {
        guard let attempt else { return "Queued" }
        if let error = attempt.errorMessage { return error }
        if let cancellation = attempt.cancellationDetail { return cancellation }
        if attempt.state == .starting || attempt.state == .running,
           let latestActivity = attempt.activity.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return latestActivity.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch attempt.state {
        case .queued: return "Queued"
        case .starting: return "Starting local harness…"
        case .running: return attempt.finalResponse.isEmpty ? "Running…" : "Streaming response…"
        case .waitingForApproval: return "Waiting for your approval"
        case .completed: return "Response complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled by you"
        case .timedOut: return "Timed out"
        case .interrupted: return "Interrupted"
        }
    }

    private func attempt(for laneID: UUID) -> AgentAttempt? {
        guard let attemptID = attemptIDsByLane[laneID] else { return nil }
        if let active = activeRun?.agents.flatMap(\.attempts).first(where: { $0.id == attemptID }) { return active }
        return historyRuns.values.flatMap(\.agents).flatMap(\.attempts).first(where: { $0.id == attemptID })
    }

    private func attemptByID(_ id: UUID) -> AgentAttempt? {
        if let active = activeRun?.agents.flatMap(\.attempts).first(where: { $0.id == id }) { return active }
        return historyRuns.values.lazy.flatMap(\.agents).flatMap(\.attempts).first(where: { $0.id == id })
    }

    private func ownedProcessIsStillRunning(_ attempt: AgentAttempt) -> Bool {
        let owned = attempt.ownership
        return identityStillMatches(pid: owned.processID, serialized: owned.processIdentity)
            || identityStillMatches(pid: owned.serverProcessID, serialized: owned.serverIdentity)
    }

    private func identityStillMatches(pid: Int32?, serialized: String) -> Bool {
        guard let pid, pid > 0, let current = OwnedProcessService.identity(for: pid) else { return false }
        return serialized.isEmpty || current.serialized == serialized
    }

    private func measured(_ value: Double?, provenance: MetricProvenance?) -> String {
        guard let value, provenance != .unavailable else { return "Unavailable" }
        return String(format: "%.1fs", value)
    }
    private func tokenText(_ metrics: AttemptMetrics?) -> String {
        guard let metrics, metrics.tokenProvenance != .unavailable else { return "Unavailable" }
        return [metrics.inputTokens, metrics.outputTokens].compactMap { $0 }.map(String.init).joined(separator: " + ")
    }
    private func costText(_ metrics: AttemptMetrics?) -> String {
        guard let cost = metrics?.cost, metrics?.costProvenance != .unavailable else { return "Unavailable" }
        return "\(cost)"
    }
    private func updateTimeouts() { configurations = configurationPolicy.applyingTimeout(to: configurations, timeoutMinutes: timeoutMinutes, usesNoTimeout: usesNoTimeout) }
    private func normalizeAllConfigurations() { for configuration in configurations { normalizeConfiguration(configuration.id) } }
    private func actionable(_ error: Error) -> String { error.localizedDescription.isEmpty ? "The local operation failed. Check Settings for the harness path and diagnostics." : error.localizedDescription }

    private func notifyCompletion(for run: BenchmarkRun) {
        let content = UNMutableNotificationContent(); content.title = "JBench run finished"; content.body = "\(run.agents.count) lanes: \(run.state.rawValue)."; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
    }

    private func notifyApproval(_ approval: ApprovalRequest, lane: Int) {
        let content = UNMutableNotificationContent()
        content.title = "JBench approval needed"
        content.body = hidesReviewIdentities
            ? "A candidate needs permission to continue."
            : "Lane \(lane): \(approval.summary)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-\(approval.id.uuidString)", content: content, trigger: nil))
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(filePath: NSTemporaryDirectory())
        return base.appending(path: "JBench", directoryHint: .isDirectory)
    }
    private static func makeDiscovery(settings: DiscoverySettings, cacheURL: URL) -> DiscoveryService {
        let codex = CodexAppServerAdapter()
        let openCode = OpenCodeAdapter()
        let agy = AgyAdapter()
        return DiscoveryService(settings: settings, adapters: [.codex: codex, .openCode: openCode, .agy: agy], cacheURL: cacheURL)
    }
    private static func loadDiscoverySettings() -> DiscoverySettings {
        guard let data = UserDefaults.standard.data(forKey: "JBench.discoverySettings"), let settings = try? JSONDecoder().decode(DiscoverySettings.self, from: data) else { return .init() }
        return settings
    }
    private static func saveDiscoverySettings(_ settings: DiscoverySettings) { UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "JBench.discoverySettings") }

    private static func loadAppearance() -> AppAppearance {
        guard let rawValue = UserDefaults.standard.string(forKey: "JBench.appearance"),
              let appearance = AppAppearance(rawValue: rawValue) else { return .system }
        return appearance
    }

    private static func saveAppearance(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: "JBench.appearance")
    }

    func applyAppearanceToApplication() {
        NSApp?.appearance = appearance.nsAppearance
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
