import SwiftUI
import JBenchCore

struct HistoryView: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        Group {
            if let item = store.selectedHistory {
                HistoryDetail(store: store, item: item)
            } else {
                ContentUnavailableView("No matching runs", systemImage: "magnifyingglass")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.selectedHistoryID) { _, _ in store.loadVerdictForSelectedHistory() }
        .confirmationDialog("Delete local history?", isPresented: $store.isShowingDeletionConfirmation, titleVisibility: .visible) {
            Button("Delete record", role: .destructive) { store.confirmHistoryDeletion(deleteEvidence: false) }
            Button("Delete record and evidence", role: .destructive) { store.confirmHistoryDeletion(deleteEvidence: true) }
        } message: {
            Text(store.deletionImpact)
        }
        .confirmationDialog("Run editable history again?", isPresented: $store.isShowingRunAgainConfirmation, titleVisibility: .visible) {
            Button("Use current clean commit") { store.confirmRunAgainWithCurrentCommit() }
        } message: {
            Text(store.runAgainCommitMessage)
        }
        .alert("Rename run", isPresented: $store.isShowingHistoryTitleRename) {
            TextField("Title", text: $store.historyTitleRename)
            Button("Rename") { store.renameHistoryTitle() }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct HistoryDetail: View {
    @Bindable var store: JBenchAppStore
    let item: HistoryPresentation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title2).fontWeight(.semibold)
                        HStack { StateBadge(state: item.state); Text(item.date, format: .dateTime.month(.wide).day().year().hour().minute()).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Rename", systemImage: "pencil") { store.prepareRenameHistoryTitle(item) }
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Markdown report") { store.exportMarkdown(for: item) }
                        Button("Evidence bundle") { store.exportEvidenceBundle(for: item) }
                    }
                }
                HStack {
                    Button("Run Again", systemImage: "arrow.clockwise") { store.runAgain(item) }
                    Button("Delete", systemImage: "trash", role: .destructive) { store.prepareHistoryDeletion(item.id) }
                    Spacer()
                }
                GroupBox("Run evidence") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                        GridRow { Text("Directory").foregroundStyle(.secondary); Text(item.directory).textSelection(.enabled) }
                        GridRow { Text("Mode").foregroundStyle(.secondary); Text(item.mode == .readOnly ? "Read-only (adapter proof required)" : "Editable worktrees") }
                        GridRow { Text("Prompt").foregroundStyle(.secondary); Text(item.prompt).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                if !item.judgeConfigurations.isEmpty {
                    HistoryJudgeResults(configurations: item.judgeConfigurations, votes: item.judgeVotes, lanes: item.lanes, hidesIdentity: store.hidesReviewIdentities)
                }
                LanesWorkspace(store: store, lanes: item.lanes, runID: item.id)
            }
            .padding(20)
        }
    }
}

private struct HistoryJudgeResults: View {
    let configurations: [JudgeConfiguration]
    let votes: [JudgeVote]
    let lanes: [LanePresentation]
    let hidesIdentity: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(configurations) { judge in
                    judgeResult(judge)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("AI judge results", systemImage: "checkmark.seal")
        }
    }

    @ViewBuilder
    private func judgeResult(_ judge: JudgeConfiguration) -> some View {
        let vote = votes.first(where: { $0.judge.id == judge.id })
        let judgeDetails = [judge.harness.rawValue, judge.model, judge.reasoning ?? "Default"].joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(judge.name.isEmpty ? "Unnamed judge" : judge.name, systemImage: "checkmark.seal")
                    .font(.headline)
                Spacer()
                Text(judgeDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let vote {
                let detail = vote.errorMessage ?? vote.reasoning ?? "No reasoning supplied"
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Winner")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vote.winningBlindLabel ?? "No winner")
                        .font(.caption.weight(.medium))
                    if !hidesIdentity,
                       let winningAgentRunID = vote.winningAgentRunID,
                       let candidate = lanes.first(where: { $0.id == winningAgentRunID }) {
                        Text("· \(candidate.configuration.harness.rawValue) / \(candidate.configuration.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(vote.errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            } else {
                Text("Awaiting result")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PresetsView: View {
    @Bindable var store: JBenchAppStore
    @State private var renameTarget: Preset?
    @State private var renameText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Presets").font(.largeTitle).fontWeight(.semibold); Text("Save two to six native harness configurations.").foregroundStyle(.secondary) }
                Spacer()
                Button("Save current selection", systemImage: "plus") { store.savePreset() }.buttonStyle(.borderedProminent)
            }
            List {
                ForEach(store.presets) { preset in
                    HStack {
                        Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) { Text(preset.name).font(.headline); Text(preset.agents.map { "\($0.harness == .codex ? "Codex" : "OpenCode") · \($0.model) · \($0.reasoning ?? "Default")" }.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Button("Use") { store.applyPreset(preset) }
                        Button("Update") { store.replacePreset(preset) }
                        Button("Rename") { renameTarget = preset; renameText = preset.name }
                        Button("Move up") { store.movePreset(preset, by: -1) }.labelStyle(.iconOnly).imageScale(.small)
                        Button("Move down") { store.movePreset(preset, by: 1) }.labelStyle(.iconOnly).imageScale(.small)
                        Button("Delete", role: .destructive) { store.deletePreset(preset) }
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
        .alert("Rename preset", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Preset name", text: $renameText)
            Button("Rename") { if let renameTarget { store.renamePreset(renameTarget, to: renameText) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }
}

struct SettingsView: View {
    @Bindable var store: JBenchAppStore
    var body: some View {
        TabView {
            AppearanceSettings(store: store).tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            SettingsDetailView(store: store, showsAppearance: false).tabItem { Label("Harnesses", systemImage: "cpu") }
            NotificationsSettings(store: store).tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct AppearanceSettings: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        Form {
            AppearancePreferenceSection(store: store)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AppearancePreferenceSection: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $store.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text("System follows macOS. Light and Dark update JBench and native panels immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsDetailView: View {
    @Bindable var store: JBenchAppStore
    var showsAppearance = true

    var body: some View {
        Form {
            if showsAppearance {
                AppearancePreferenceSection(store: store)
            }
            Section("Harness diagnostics") {
                ForEach(store.diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 4) {
                        let harnessIcon: String = switch diagnostic.harness {
                        case .codex: "sparkles"
                        case .openCode: "hexagon.fill"
                        case .agy: "arrow.triangle.2.circlepath"
                        case .fake: "theatermasks.fill"
                        }
                        let harnessTitle: String = switch diagnostic.harness {
                        case .codex: "Codex"
                        case .openCode: "OpenCode"
                        case .agy: "Antigravity"
                        case .fake: "Demo"
                        }
                        HStack {
                            Image(systemName: harnessIcon).foregroundStyle(.tint)
                            Text(harnessTitle).font(.headline)
                            Spacer()
                            Label(diagnostic.status == .ready ? "Ready" : "Unavailable", systemImage: diagnostic.status == .ready ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(diagnostic.status == .ready ? .green : .red)
                        }
                        Text("\(diagnostic.version) · \(diagnostic.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(diagnostic.discovery).font(.caption).foregroundStyle(.secondary)
                        if diagnostic.status != .ready {
                            let loginCmd: String = switch diagnostic.harness {
                            case .codex: "codex login"
                            case .openCode: "opencode auth login"
                            case .agy: "agy"
                            case .fake: "demo"
                            }
                            Text("Login command: \(loginCmd)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Refresh discovery") { Task { await store.refreshDiscovery() } }
            }
            Section("Overrides") {
                TextField("Codex executable", text: Binding(get: { store.discoverySettings.executableOverrides[.codex] ?? "" }, set: { store.updateExecutableOverride($0, for: .codex) }))
                TextField("OpenCode executable", text: Binding(get: { store.discoverySettings.executableOverrides[.openCode] ?? "" }, set: { store.updateExecutableOverride($0, for: .openCode) }))
                TextField("Antigravity executable", text: Binding(get: { store.discoverySettings.executableOverrides[.agy] ?? "" }, set: { store.updateExecutableOverride($0, for: .agy) }))
            }
            Section("Custom model fallback") {
                HStack {
                    TextField("Codex native model ID", text: $store.customCodexModel)
                    Button("Add") { store.addCustomModel(for: .codex) }
                }
                HStack {
                    TextField("OpenCode native model ID", text: $store.customOpenCodeModel)
                    Button("Add") { store.addCustomModel(for: .openCode) }
                }
                HStack {
                    TextField("Antigravity native model ID", text: $store.customAgyModel)
                    Button("Add") { store.addCustomModel(for: .agy) }
                }
                Text("Custom IDs are not normalized. They stay unverified until a harness observes them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Run defaults") {
                Toggle("No timeout", isOn: $store.usesNoTimeout)
                Stepper("Timeout: \(store.timeoutMinutes) minutes", value: $store.timeoutMinutes, in: 1...180)
                    .disabled(store.usesNoTimeout)
                Text("No live or paid harness prompt is run by this screen.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Read-only verification") {
                Label("Codex uses its app-server read-only sandbox.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Label("Antigravity uses its CLI sandbox isolation.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Label("OpenCode read-only is blocked until a version-specific restriction and sentinel diagnostic succeeds.", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct NotificationsSettings: View {
    @Bindable var store: JBenchAppStore
    var body: some View {
        Form {
            Section("Completion") {
                Toggle("Notify when a run completes", isOn: Binding(get: { store.notifyOnCompletion }, set: { store.setNotificationsEnabled($0) }))
                Text("JBench keeps active lane status in the menu bar while the main window is closed.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct StateBadge: View {
    let state: AggregateRunState
    private var color: Color { state == .completed ? .green : state == .partiallyCompleted ? .orange : .red }
    var body: some View {
        Text(state == .partiallyCompleted ? "Partial" : state.rawValue.capitalized)
            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }
}
