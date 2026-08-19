import AppKit
import SwiftUI
import JBenchCore

struct LanesWorkspace: View {
    @Bindable var store: JBenchAppStore
    let lanes: [LanePresentation]
    var runID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Review mode", selection: $store.reviewMode) {
                    ForEach(RunPresentation.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                Spacer()
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Markdown report") { store.exportMarkdown(runID: runID) }
                    Button("Evidence bundle") { store.exportEvidenceBundle(runID: runID) }
                }
                Button("Columns", systemImage: "rectangle.split.3x1") { }
            }

            if store.reviewMode == .sideBySide {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(lanes) { lane in
                            LaneCard(store: store, lane: lane)
                                .frame(width: 380)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                BlindReviewView(store: store, lanes: lanes)
            }
        }
        .confirmationDialog("Export sensitive run data?", isPresented: $store.isShowingExportWarning, titleVisibility: .visible) {
            Button("Export") { store.confirmExport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Prompts, tool output, raw events, and patches can contain sensitive data. Review the destination before you share the export.")
        }
        .sheet(isPresented: $store.isShowingRawEvidence) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(store.rawEvidenceTitle).font(.title2).fontWeight(.semibold)
                    Spacer()
                    Button("Done") { store.isShowingRawEvidence = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(store.rawEvidenceText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(minWidth: 760, minHeight: 520)
        }
    }
}

private struct LaneCard: View {
    @Bindable var store: JBenchAppStore
    let lane: LanePresentation

    private var tint: Color {
        switch lane.configuration.harness {
        case .codex: lane.configuration.model == "Luna" ? .purple : .blue
        case .openCode: .orange
        case .fake: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                Image(systemName: lane.configuration.harness == .codex ? "sparkles" : "hexagon.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(laneNumber). \(harnessName) · \(lane.configuration.model) · \(lane.configuration.reasoning ?? "Default")")
                        .font(.headline)
                        .lineLimit(2)
                    Label(lane.activity, systemImage: stateIcon)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                }
                Spacer(minLength: 0)
                laneMenu
            }

            if let approval = lane.approval {
                ApprovalCard(store: store, lane: lane, approval: approval)
            }

            HStack(alignment: .top, spacing: 12) {
                SettingsColumn(title: "Requested", values: [
                    ("Harness", harnessName),
                    ("Model", lane.configuration.model),
                    ("Reasoning", lane.configuration.reasoning ?? "Default")
                ], tint: .blue)
                Divider().frame(height: 75)
                SettingsColumn(title: "Observed", values: [
                    ("Model", lane.observedModel ?? "Unavailable"),
                    ("Reasoning", lane.observedReasoning ?? "Unavailable")
                ], tint: .green)
            }

            Divider()
            Group {
                if lane.state == .running || lane.state == .starting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(lane.output.isEmpty ? "Waiting for streamed output…" : lane.output)
                            .foregroundStyle(.secondary)
                    }
                } else if lane.output.isEmpty {
                    ContentUnavailableView("No response", systemImage: "text.badge.xmark", description: Text(lane.activity))
                        .frame(height: 175)
                } else {
                    Text((try? AttributedString(markdown: lane.output)) ?? AttributedString(lane.output))
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 184, alignment: .topLeading)

            if let worktree = lane.worktree {
                WorktreeControls(store: store, lane: lane, worktree: worktree)
            }

            Divider()
            HStack(spacing: 15) {
                MetricItem(icon: "clock", value: lane.elapsed, label: "Elapsed")
                MetricItem(icon: "number.square", value: lane.tokens, label: "Tokens")
                MetricItem(icon: "dollarsign.circle", value: lane.cost, label: "Cost")
                Spacer()
                Button("Raw Events") { store.showRawEvidence(for: lane.id) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                MetricItem(icon: stateIcon, value: labelForState, label: "Status", color: stateColor)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) { Rectangle().fill(tint).frame(height: 3).clipShape(RoundedRectangle(cornerRadius: 12)) }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
        .contextMenu {
            Button("Copy response") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lane.output, forType: .string) }
            if !lane.state.isTerminal { Button("Cancel lane", role: .destructive) { store.cancel(laneID: lane.id) } }
        }
    }

    private var laneNumber: Int { (store.lanes.firstIndex(where: { $0.id == lane.id }) ?? 0) + 1 }
    private var harnessName: String {
        switch lane.configuration.harness {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .fake: "Demo"
        }
    }
    private var stateIcon: String {
        switch lane.state {
        case .completed: "checkmark.circle.fill"
        case .running, .starting: "arrow.triangle.2.circlepath"
        case .waitingForApproval: "hand.raised.fill"
        case .failed, .timedOut: "exclamationmark.triangle.fill"
        case .cancelled, .interrupted: "xmark.circle.fill"
        case .queued: "clock"
        }
    }
    private var stateColor: Color { lane.state == .completed ? .green : lane.state == .failed || lane.state == .timedOut ? .red : lane.state == .cancelled ? .secondary : .orange }
    private var labelForState: String { lane.state.rawValue.capitalized }

    @ViewBuilder private var laneMenu: some View {
        Menu {
            if !lane.state.isTerminal { Button("Cancel Lane", role: .destructive) { store.cancel(laneID: lane.id) } }
            if lane.state == .failed || lane.state == .timedOut { Button("Retry") { store.retry(laneID: lane.id) } }
            Button("Copy Response") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lane.output, forType: .string) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }
}

private struct SettingsColumn: View {
    let title: String
    let values: [(String, String)]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(values, id: \.0) { item in
                HStack(spacing: 4) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(tint.opacity(0.09), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ApprovalCard: View {
    @Bindable var store: JBenchAppStore
    let lane: LanePresentation
    let approval: ApprovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval needed", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text(approval.summary).font(.caption)
            HStack {
                Button("Decline", role: .destructive) { store.reply(.decline, laneID: lane.id) }
                Spacer()
                Button("Approve once") { store.reply(.approveOnce, laneID: lane.id) }
                Button("For attempt") { store.reply(.approveForAttempt, laneID: lane.id) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct WorktreeControls: View {
    @Bindable var store: JBenchAppStore
    let lane: LanePresentation
    let worktree: WorktreePresentation
    @State private var showsDiff = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Editable worktree · \(worktree.changedFiles) changed files", systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(showsDiff ? "Hide Diff" : "Show Diff") { showsDiff.toggle() }
                    .disabled(worktree.diff.isEmpty)
                Button("Open") { store.worktreeAction("Open", lane: lane) }
                Button("Export Patch") { store.worktreeAction("Export patch", lane: lane) }
                Button("Keep") { store.worktreeAction("Keep", lane: lane) }
                    .disabled(!store.canTransferWorktree(for: lane.id))
                Button("Discard", role: .destructive) { store.worktreeAction("Discard", lane: lane) }
                    .disabled(!store.canTransferWorktree(for: lane.id))
            }
            .controlSize(.small)
            if showsDiff {
                ScrollView([.horizontal, .vertical]) {
                    Text(worktree.diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 240)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BlindReviewView: View {
    @Bindable var store: JBenchAppStore
    let lanes: [LanePresentation]
    @State private var expandedResponses: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Blind review").font(.headline)
                    Text(store.isRevealOn ? "Identities revealed. Your manual verdict is stored with the run." : "Model and harness names are hidden. There is no automatic judge or prose diff.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Reveal identities", isOn: $store.isRevealOn)
                    .toggleStyle(.switch)
                    .disabled(!store.canRevealIdentities)
            }
            ForEach(lanes.sorted { $0.blindReviewOrder < $1.blindReviewOrder }) { lane in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(candidateTitle(for: lane))
                            .font(.headline)
                        Spacer()
                        if store.winningLaneID == lane.id {
                            Button("Selected winner") { store.winningLaneID = lane.id }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Select winner") { store.winningLaneID = lane.id }
                                .buttonStyle(.bordered)
                        }
                    }
                    Text(lane.output)
                        .lineLimit(expandedResponses.contains(lane.id) ? nil : 4)
                        .textSelection(.enabled)
                    Button {
                        if expandedResponses.contains(lane.id) {
                            expandedResponses.remove(lane.id)
                        } else {
                            expandedResponses.insert(lane.id)
                        }
                    } label: {
                        Label(
                            expandedResponses.contains(lane.id) ? "Show less" : "Show full response",
                            systemImage: expandedResponses.contains(lane.id) ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10)).overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
            }
            TextField("Why this response won (optional)", text: $store.reviewNote, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Button("Skip verdict and reveal") { store.skipManualVerdict() }
                Spacer()
                Button("Save manual verdict") { store.saveManualVerdict() }.buttonStyle(.borderedProminent).disabled(store.winningLaneID == nil)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
    }

    private func candidateTitle(for lane: LanePresentation) -> String {
        if store.isRevealOn {
            let harness: String
            switch lane.configuration.harness {
            case .codex: harness = "Codex"
            case .openCode: harness = "OpenCode"
            case .fake: harness = "Demo"
            }
            return "\(harness) · \(lane.configuration.model)"
        }
        let ordered = lanes.sorted { $0.blindReviewOrder < $1.blindReviewOrder }
        let index = ordered.firstIndex(where: { $0.id == lane.id }) ?? 0
        return "Candidate \(String(UnicodeScalar(65 + index)!))"
    }
}

struct SummaryStrip: View {
    let lanes: [LanePresentation]
    var body: some View {
        HStack(spacing: 0) {
            SummaryItem(icon: "person.2.fill", title: "Manual comparison", value: "JBench never selects a winner", tint: .blue)
            Divider().frame(height: 56)
            SummaryItem(icon: "eye.fill", title: "Observed telemetry", value: "Unavailable stays unavailable", tint: .green)
            Divider().frame(height: 56)
            SummaryItem(icon: "checkmark.seal.fill", title: "Verdict", value: "Use Blind Review to decide", tint: .orange)
        }
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
    }
}

private struct SummaryItem: View {
    let icon: String; let title: String; let value: String; let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3).frame(width: 34, height: 34).background(tint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline).lineLimit(1) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

private struct MetricItem: View {
    let icon: String; let value: String; let label: String; var color: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) { Image(systemName: icon).foregroundStyle(color); Text(value).font(.caption).lineLimit(1) }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
