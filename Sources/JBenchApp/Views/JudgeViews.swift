import SwiftUI
import JBenchCore

struct JudgesInspector: View {
    @Bindable var store: JBenchAppStore
    @State private var selectedJudgeID: UUID?

    private var judgeEditingBlocked: Bool {
        store.section != .newRun && (store.isJudgingActive || store.isBackgroundRunActive)
    }

    private var selectedIndex: Int? {
        guard let selectedJudgeID else { return store.judgeConfigurations.indices.first }
        return store.judgeConfigurations.firstIndex { $0.id == selectedJudgeID } ?? store.judgeConfigurations.indices.first
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Judges").font(.headline)
                        Text("Ask named reviewers to pick a winner").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Judge", systemImage: "plus") { store.addJudge(); selectedJudgeID = store.judgeConfigurations.last?.id }
                        .disabled(judgeEditingBlocked)
                }
                if store.judgeConfigurations.isEmpty {
                    ContentUnavailableView("No judges configured", systemImage: "person.crop.circle.badge.questionmark", description: Text("Candidate results remain available without AI judges."))
                        .frame(minHeight: 100)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                            ForEach(store.judgeConfigurations) { judge in
                                Button {
                                    selectedJudgeID = judge.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.crop.circle")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(judge.name.isEmpty ? "Unnamed judge" : judge.name).lineLimit(1)
                                            Text("\(judge.harness.rawValue) · \(judge.model)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if store.isJudgingActive { ProgressView().controlSize(.mini) }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background((selectedJudgeID == judge.id ? Color.accentColor.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        }
                        .frame(minHeight: 64, maxHeight: 170)
                        Divider()
                        if let index = selectedIndex {
                            JudgeEditor(store: store, judge: $store.judgeConfigurations[index])
                        }
                    }
                }
                if let status = store.judgeStatusMessage {
                    Label(status, systemImage: store.isJudgingActive ? "hourglass" : "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.judgeConfigurations) { judge in
                    if let vote = store.judgeVotes.first(where: { $0.judge.id == judge.id }) {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: vote.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(vote.errorMessage == nil ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(vote.judge.name): \(store.judgeVoteDisplay(vote))").font(.caption.weight(.medium))
                                Text(vote.errorMessage ?? vote.reasoning ?? "No reasoning supplied").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
        .groupBoxStyle(PanelGroupBoxStyle())
        .onAppear { selectedJudgeID = selectedJudgeID ?? store.judgeConfigurations.first?.id }
    }
}

private struct JudgeEditor: View {
    @Bindable var store: JBenchAppStore
    @Binding var judge: JudgeConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                TextField("Judge name", text: $judge.name).textFieldStyle(.roundedBorder)
                Button("Delete", systemImage: "trash", role: .destructive) { store.removeJudge(judge.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Harness") {
                    Picker("Harness", selection: $judge.harness) {
                        Text("Codex").tag(HarnessKind.codex)
                        if judge.harness == .openCode {
                            Text("OpenCode (read-only unavailable)").tag(HarnessKind.openCode)
                        }
                        Text("Antigravity").tag(HarnessKind.agy)
                        if store.isDemoMode { Text("Demo").tag(HarnessKind.fake) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                LabeledContent("Model") {
                    FuzzyModelPicker(harness: judge.harness, selectedModel: $judge.model, availableModels: judge.harness == .fake ? [judge.model] : store.models(for: judge.harness), catalogEntries: judge.harness == .fake ? [] : store.catalog(for: judge.harness))
                        .frame(maxWidth: .infinity)
                }
                LabeledContent("Reasoning") {
                    Picker("Reasoning", selection: Binding(get: { judge.reasoning ?? "Default" }, set: { judge.reasoning = $0 == "Default" ? nil : $0 })) {
                        ForEach(judge.harness == .fake ? ["Default", "Deterministic"] : store.reasoningValues(for: judge), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: judge.harness) { _, _ in store.normalizeJudge(judge.id) }
            .onChange(of: judge.model) { _, _ in store.normalizeJudge(judge.id) }
            if judge.harness == .openCode {
                Text("OpenCode judges are unavailable until read-only verification is supported.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text("Judging guidance").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { judge.steeringPrompt ?? "" }, set: { value in
                judge.steeringPrompt = value.isEmpty ? nil : value
            }))
                .font(.callout).scrollContentBackground(.hidden).padding(5)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .frame(minHeight: 82)
            Text("Example: focus on correctness, taste, or evidence quality.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(store.judgeActionTitle, systemImage: "arrow.clockwise") { store.rerunJudges() }
                    .disabled(store.isJudgingActive || !store.canRerunJudges)
            }
        }
        .disabled(store.section != .newRun && (store.isJudgingActive || store.isBackgroundRunActive))
    }
}
