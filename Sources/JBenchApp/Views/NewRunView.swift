import SwiftUI
import JBenchCore

struct NewRunView: View {
    @Bindable var store: JBenchAppStore
    @State private var showsSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.lanes.isEmpty {
                    ComposerCard(store: store)
                    ConfigurationCard(store: store)
                    JudgesInspector(store: store)
                } else {
                    CompletedRunHeader(store: store) { showsSetup = true }
                    if showsSetup && !store.hidesReviewIdentities {
                        ComposerCard(store: store)
                        ConfigurationCard(store: store)
                    }
                }
                if !store.lanes.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        LanesWorkspace(store: store, lanes: store.lanes)
                        JudgesInspector(store: store)
                            .frame(width: 330)
                    }
                } else {
                    LanesWorkspace(store: store, lanes: store.lanes)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        .onChange(of: store.hidesReviewIdentities) { _, hidesIdentities in
            if hidesIdentities {
                showsSetup = false
            }
        }
    }
}

private struct CompletedRunHeader: View {
    @Bindable var store: JBenchAppStore
    let editSetup: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.runTitle.isEmpty ? "Prompt" : store.runTitle)
                        .font(.headline)
                    Spacer()
                    Button("Edit setup", systemImage: "slider.horizontal.3") { editSetup() }
                        .disabled(store.hidesReviewIdentities)
                        .help(store.hidesReviewIdentities ? "Reveal identities before editing setup." : "Edit the prompt and agent setup for this run.")
                }
                Text(store.prompt)
                    .font(.title3)
                    .lineLimit(2)
                Divider()
                HStack(spacing: 8) {
                    Label(store.directory, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if store.hidesReviewIdentities {
                        Text("\(store.configurations.count) identities hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.55), in: Capsule())
                            .accessibilityLabel("\(store.configurations.count) identities hidden")
                    } else {
                        ForEach(store.configurations) { configuration in
                            Text("\(configuration.harness == .fake ? "Demo" : configuration.harness.rawValue) · \(configuration.model) · \(configuration.reasoning ?? "Default")")
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.quaternary.opacity(0.55), in: Capsule())
                        }
                    }
                }
            }
            .padding(4)
        }
        .groupBoxStyle(PanelGroupBoxStyle())
    }
}

private struct ComposerCard: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prompt")
                        .font(.headline)
                    Spacer()
                    Text("\(store.prompt.count) / 10,000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Run title (optional)", text: $store.runTitle)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $store.prompt)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92)

                Divider()
                HStack(spacing: 10) {
                    Label("Working directory", systemImage: "folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(store.directory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { store.chooseDirectory() }
                }
                HStack(spacing: 8) {
                    Text("Execution")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Execution", selection: $store.executionMode) {
                        Text("Read-only").tag(ExecutionMode.readOnly)
                        Text("Editable worktrees").tag(ExecutionMode.editable).disabled(!store.canUseEditable)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    Text(store.executionMode == .readOnly ? "Codex has an enforced sandbox. OpenCode stays blocked until its sentinel diagnostic is verified." : "Clean Git required. Each lane gets a worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Label(store.repositoryExplanation, systemImage: store.canUseEditable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(store.canUseEditable ? Color.secondary : Color.orange)
                if store.isDemoMode {
                    HStack {
                        Label("Provider-free demo mode", systemImage: "testtube.2")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Use local harnesses") { store.leaveDemoMode() }
                    }
                }
            }
            .padding(4)
        }
        .groupBoxStyle(PanelGroupBoxStyle())
    }
}

private struct ConfigurationCard: View {
    @Bindable var store: JBenchAppStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Agents (\(store.configurations.count))")
                            .font(.headline)
                        Text("These agents will run in parallel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add lane", systemImage: "plus") { store.addConfiguration() }
                        .disabled(store.configurations.count == 6)
                    Button("Run \(store.configurations.count) Agents", systemImage: "play.fill") {
                        store.start(prompt: store.prompt, directory: store.directory, mode: store.executionMode, configurations: store.configurations)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canRun)
                }
                ForEach($store.configurations) { $configuration in
                    ConfigurationRow(store: store, configuration: $configuration, number: store.configurations.firstIndex(where: { $0.id == configuration.id }).map { $0 + 1 } ?? 1, canRemove: store.configurations.count > 2) {
                        store.removeConfiguration(configuration.id)
                    }
                }
            }
            .padding(4)
        }
        .groupBoxStyle(PanelGroupBoxStyle())
    }
}

private struct ConfigurationRow: View {
    @Bindable var store: JBenchAppStore
    @Binding var configuration: AgentConfiguration
    let number: Int
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: harnessIcon)
                .foregroundStyle(harnessColor)
                .frame(width: 24)
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Picker("Harness", selection: $configuration.harness) {
                Text("Codex").tag(HarnessKind.codex)
                Text("OpenCode").tag(HarnessKind.openCode)
                Text("Antigravity (agy)").tag(HarnessKind.agy)
                if store.isDemoMode { Text("Demo").tag(HarnessKind.fake) }
            }
            .onChange(of: configuration.harness) { _, _ in store.normalizeConfiguration(configuration.id) }
            .labelsHidden()
            .frame(width: 120)
            FuzzyModelPicker(
                harness: configuration.harness,
                selectedModel: $configuration.model,
                availableModels: configuration.harness == .fake
                    ? [configuration.model]
                    : store.models(for: configuration.harness),
                catalogEntries: configuration.harness == .fake
                    ? []
                    : store.catalog(for: configuration.harness)
            )
            .onChange(of: configuration.model) { _, _ in store.normalizeConfiguration(configuration.id) }
            .frame(width: 170)
            Picker("Reasoning", selection: Binding(get: { configuration.reasoning ?? "Default" }, set: { configuration.reasoning = $0 == "Default" ? nil : $0 })) {
                ForEach(configuration.harness == .fake ? ["Default", "Deterministic"] : store.reasoningValues(for: configuration), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            Picker("Approval", selection: $configuration.approvalPolicy) {
                Text("Ask").tag(ApprovalPolicy.askEveryTime)
                Text("Allow attempt").tag(ApprovalPolicy.allowForAttempt)
                Text("Deny").tag(ApprovalPolicy.denyAll)
            }
            .labelsHidden()
            .frame(width: 120)
            Spacer()
            Button("Remove", systemImage: "minus.circle") { remove() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canRemove)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var harnessIcon: String {
        switch configuration.harness {
        case .codex: "sparkles"
        case .openCode: "hexagon.fill"
        case .agy: "atom"
        case .fake: "testtube.2"
        }
    }

    private var harnessColor: Color {
        switch configuration.harness {
        case .codex: .blue
        case .openCode: .orange
        case .agy: .teal
        case .fake: .gray
        }
    }
}
