import AppKit
import SwiftUI
import JBenchCore

struct LanesWorkspace: View {
    @Bindable var store: JBenchAppStore
    let lanes: [LanePresentation]
    var runID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Review mode", selection: $store.reviewMode) {
                    ForEach(RunPresentation.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                overallStatusView

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
                    .frame(minHeight: 620)
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

    @ViewBuilder
    private var overallStatusView: some View {
        if !lanes.isEmpty {
            let runningCount = lanes.filter { $0.state == .running || $0.state == .starting }.count
            let approvalCount = lanes.filter { $0.state == .waitingForApproval }.count
            let queuedCount = lanes.filter { $0.state == .queued }.count
            let completedCount = lanes.filter { $0.state == .completed }.count
            let failedCount = lanes.filter { $0.state == .failed || $0.state == .timedOut }.count
            let cancelledCount = lanes.filter { $0.state == .cancelled }.count
            let interruptedCount = lanes.filter { $0.state == .interrupted }.count
            let stoppedCount = cancelledCount + interruptedCount

            if approvalCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(approvalCount == 1 ? "Approval needed for 1 agent" : "Approval needed for \(approvalCount) agents")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5) }
            } else if runningCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Running \(runningCount) of \(lanes.count) agents…")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.5) }
            } else if queuedCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Queued \(queuedCount) of \(lanes.count) agents…")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5) }
            } else if completedCount == lanes.count {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("All \(lanes.count) agents finished")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5) }
            } else if failedCount == lanes.count {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("All agents failed")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5) }
            } else if stoppedCount == lanes.count {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(interruptedCount > 0 ? "Run interrupted" : "All agents cancelled")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5) }
            } else if completedCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    let summaryText: String = {
                        if failedCount > 0 && stoppedCount > 0 {
                            return "\(completedCount) done, \(failedCount) failed, \(stoppedCount) stopped"
                        } else if failedCount > 0 {
                            return "\(completedCount) done, \(failedCount) failed"
                        } else {
                            return "\(completedCount) done, \(stoppedCount) stopped"
                        }
                    }()
                    Text(summaryText)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5) }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("\(failedCount) failed, \(stoppedCount) stopped")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5) }
            }
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
        case .agy: .teal
        case .fake: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                Image(systemName: lane.configuration.harness == .codex ? "sparkles" : (lane.configuration.harness == .agy ? "atom" : "hexagon.fill"))
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(laneNumber). \(harnessName) · \(lane.configuration.model) · \(lane.configuration.reasoning ?? "Default")")
                            .font(.headline)
                            .lineLimit(2)
                        LaneStatusBadge(state: lane.state)
                    }
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
        case .agy: "Antigravity"
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
    var hidesSensitiveSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval needed", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text(hidesSensitiveSummary ? "This candidate needs permission to continue." : approval.summary)
                .font(.caption)
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
    @State private var activeLaneID: UUID?
    @State private var pinnedLaneID: UUID?
    @State private var selectedSectionID: String?
    @State private var scrollTargetID: String?
    @FocusState private var isReaderFocused: Bool

    private var orderedLanes: [LanePresentation] {
        lanes.sorted {
            if $0.blindReviewOrder != $1.blindReviewOrder {
                return $0.blindReviewOrder < $1.blindReviewOrder
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var activeLane: LanePresentation? {
        guard let activeLaneID else { return orderedLanes.first }
        return orderedLanes.first(where: { $0.id == activeLaneID }) ?? orderedLanes.first
    }

    private var pinnedLane: LanePresentation? {
        guard let pinnedLaneID else { return nil }
        return orderedLanes.first(where: { $0.id == pinnedLaneID })
    }

    private var activeSections: [MarkdownDocumentSection] {
        guard let activeLane else { return [] }
        return MarkdownOutlineParser.sections(in: activeLane.output)
    }

    private var outlineSections: [MarkdownDocumentSection] {
        activeSections.filter { $0.title != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()
            candidateRail
            Divider()

            if let activeLane {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        if let approval = activeLane.approval {
                            ApprovalCard(
                                store: store,
                                lane: activeLane,
                                approval: approval,
                                hidesSensitiveSummary: store.hidesReviewIdentities
                            )
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            Divider()
                        }

                        if geometry.size.width >= 760 {
                            HStack(spacing: 0) {
                                if geometry.size.width >= 980 && !outlineSections.isEmpty {
                                    BlindReviewOutline(
                                        sections: outlineSections,
                                        selectedSectionID: selectedSectionID,
                                        onSelect: selectSection
                                    )
                                    .frame(minWidth: 172, idealWidth: 204, maxWidth: 224)
                                    Divider()
                                }

                                readerSurface(for: activeLane, isWide: geometry.size.width >= 1_180)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Divider()
                                BlindVerdictInspector(
                                    store: store,
                                    lane: activeLane,
                                    candidateTitle: candidateTitle(for: activeLane),
                                    pinnedLaneID: $pinnedLaneID
                                )
                                .frame(width: 284)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 0) {
                                readerSurface(for: activeLane, isWide: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                Divider()
                                BlindVerdictInspector(
                                    store: store,
                                    lane: activeLane,
                                    candidateTitle: candidateTitle(for: activeLane),
                                    pinnedLaneID: $pinnedLaneID
                                )
                                .frame(maxHeight: 260)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No candidates to review",
                    systemImage: "text.magnifyingglass",
                    description: Text("Start a run or select a history record to read responses here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
        .focusable()
        .focusEffectDisabled()
        .focused($isReaderFocused)
        .onAppear {
            reconcileSelection()
            isReaderFocused = true
        }
        .onChange(of: lanes) { _, _ in
            reconcileSelection()
        }
        .onChange(of: store.winningLaneID) { _, _ in
            reconcileSelection()
        }
        .onKeyPress(.leftArrow) {
            moveActive(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveActive(by: 1)
            return .handled
        }
    }

    private var reviewHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Blind review")
                    .font(.title3.weight(.semibold))
                Text(store.isRevealOn ? "Identities revealed. Your manual verdict is stored with the run." : "Read one response at a time. Model and harness names stay hidden until reveal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Toggle("Reveal identities", isOn: $store.isRevealOn)
                .toggleStyle(.switch)
                .disabled(!store.canRevealIdentities)
                .help(store.canRevealIdentities ? "Show model and harness identities" : "Save or skip the verdict before revealing identities")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var candidateRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                Button {
                    moveActive(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(activeIndex == nil || activeIndex == 0)
                .accessibilityLabel("Previous candidate")

                ForEach(Array(orderedLanes.enumerated()), id: \.element.id) { index, lane in
                    Button {
                        selectLane(lane.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(candidateTitle(for: lane, index: index))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if pinnedLaneID == lane.id {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Pinned for comparison")
                            }
                            LaneStatusBadge(state: lane.state)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(minWidth: 132)
                        .background(
                            activeLaneID == lane.id ? Color.accentColor.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(activeLaneID == lane.id ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: activeLaneID == lane.id ? 1.2 : 0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidateTitle(for: lane, index: index))
                    .accessibilityValue(
                        lane.state.rawValue + (pinnedLaneID == lane.id ? ", pinned for comparison" : "")
                    )
                }

                Text(positionLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)

                Button {
                    moveActive(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(activeIndex == nil || activeIndex == orderedLanes.count - 1)
                .accessibilityLabel("Next candidate")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 58)
    }

    private var activeIndex: Int? {
        guard let activeLaneID else { return orderedLanes.isEmpty ? nil : 0 }
        return orderedLanes.firstIndex(where: { $0.id == activeLaneID })
    }

    private var positionLabel: String {
        guard let activeIndex else { return "0 of 0" }
        return "\(activeIndex + 1) of \(orderedLanes.count)"
    }

    private func candidateTitle(for lane: LanePresentation, index: Int? = nil) -> String {
        if store.isRevealOn {
            let harness: String
            switch lane.configuration.harness {
            case .codex: harness = "Codex"
            case .openCode: harness = "OpenCode"
            case .agy: harness = "Antigravity"
            case .fake: harness = "Demo"
            }
            return "\(harness) · \(lane.configuration.model)"
        }
        let position = index ?? orderedLanes.firstIndex(where: { $0.id == lane.id }) ?? 0
        guard position < 26, let scalar = UnicodeScalar(65 + position) else {
            return "Candidate \(position + 1)"
        }
        return "Candidate \(String(scalar))"
    }

    private func selectLane(_ laneID: UUID) {
        guard orderedLanes.contains(where: { $0.id == laneID }) else { return }
        activeLaneID = laneID
        selectedSectionID = nil
        scrollTargetID = nil
        isReaderFocused = true
    }

    private func moveActive(by offset: Int) {
        guard let activeIndex, !orderedLanes.isEmpty else { return }
        let nextIndex = min(max(activeIndex + offset, 0), orderedLanes.count - 1)
        guard nextIndex != activeIndex else { return }
        selectLane(orderedLanes[nextIndex].id)
    }

    private func selectSection(_ sectionID: String) {
        selectedSectionID = sectionID
        scrollTargetID = sectionID
    }

    @ViewBuilder
    private func readerSurface(for activeLane: LanePresentation, isWide: Bool) -> some View {
        if let pinnedLane, pinnedLane.id != activeLane.id {
            FocusReaderComparison(
                activeLane: activeLane,
                pinnedLane: pinnedLane,
                activeTitle: candidateTitle(for: activeLane),
                pinnedTitle: candidateTitle(for: pinnedLane),
                isWide: isWide,
                activeSelectedSectionID: $selectedSectionID,
                activeScrollTargetID: $scrollTargetID,
                onUnpin: { pinnedLaneID = nil }
            )
        } else {
            FocusReaderDocument(
                lane: activeLane,
                sections: activeSections,
                selectedSectionID: $selectedSectionID,
                scrollTargetID: $scrollTargetID
            )
        }
    }

    private func reconcileSelection() {
        guard !orderedLanes.isEmpty else {
            activeLaneID = nil
            pinnedLaneID = nil
            selectedSectionID = nil
            scrollTargetID = nil
            return
        }

        let availableIDs = Set(orderedLanes.map(\.id))
        let nextActiveID = activeLaneID.flatMap { availableIDs.contains($0) ? $0 : nil }
            ?? store.winningLaneID.flatMap { availableIDs.contains($0) ? $0 : nil }
            ?? orderedLanes[0].id
        if activeLaneID != nextActiveID {
            activeLaneID = nextActiveID
            selectedSectionID = nil
            scrollTargetID = nil
        }
        if let pinnedLaneID, !availableIDs.contains(pinnedLaneID) {
            self.pinnedLaneID = nil
        }

        let sectionIDs = Set(activeSections.map(\.id))
        if let selectedSectionID, !sectionIDs.contains(selectedSectionID) {
            self.selectedSectionID = nil
        }
    }
}

private struct BlindReviewOutline: View {
    let sections: [MarkdownDocumentSection]
    let selectedSectionID: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("Outline")
                    .font(.headline)
                    .padding(.bottom, 8)

                ForEach(sections) { section in
                    if let title = section.title {
                        Button {
                            onSelect(section.id)
                        } label: {
                            Text(title)
                                .font(section.level <= 1 ? .subheadline.weight(.medium) : .subheadline)
                                .foregroundStyle(selectedSectionID == section.id ? .primary : .secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(max(section.level - 1, 0) * 10))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .background(
                                    selectedSectionID == section.id ? Color.accentColor.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct FocusReaderDocument: View {
    let lane: LanePresentation
    let sections: [MarkdownDocumentSection]
    @Binding var selectedSectionID: String?
    @Binding var scrollTargetID: String?

    var body: some View {
        VStack(spacing: 0) {
            if lane.state == .running || lane.state == .starting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(lane.output.isEmpty ? "Waiting for streamed output…" : "Generating response…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 34)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            if lane.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(sections) { section in
                                FocusReaderSection(section: section)
                                    .frame(maxWidth: 760, alignment: .leading)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: FocusReaderSectionPositionKey.self,
                                                value: [section.id: geometry.frame(in: .named("focus-reader-scroll")).minY]
                                            )
                                        }
                                    }
                                    .id(section.id)
                            }
                        }
                        .padding(.horizontal, 34)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .coordinateSpace(name: "focus-reader-scroll")
                    .onChange(of: scrollTargetID) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            reader.scrollTo(target, anchor: .top)
                        }
                        scrollTargetID = nil
                    }
                    .onPreferenceChange(FocusReaderSectionPositionKey.self) { positions in
                        guard let visibleID = visibleSectionID(from: positions), selectedSectionID != visibleID else { return }
                        selectedSectionID = visibleID
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if sections.count > 1 {
                Label("Select text to copy", systemImage: "text.cursor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Response text")
    }

    private var emptyTitle: String {
        switch lane.state {
        case .running, .starting: "Waiting for response"
        case .queued: "Queued"
        case .waitingForApproval: "Waiting for approval"
        case .failed, .timedOut: "No response recorded"
        case .cancelled, .interrupted: "No response recorded"
        case .completed: "No response recorded"
        }
    }

    private var emptySystemImage: String {
        switch lane.state {
        case .running, .starting: "arrow.triangle.2.circlepath"
        case .queued: "clock"
        case .waitingForApproval: "hand.raised.fill"
        case .failed, .timedOut: "text.badge.xmark"
        case .cancelled, .interrupted: "xmark.circle"
        case .completed: "text.badge.xmark"
        }
    }

    private var emptyDescription: String {
        switch lane.state {
        case .running, .starting: "The response will appear here as it streams in."
        case .queued: "This candidate has not started yet."
        case .waitingForApproval: "Approve the request above to continue this candidate."
        case .failed, .timedOut: "This candidate finished without a response."
        case .cancelled, .interrupted: "This candidate stopped before returning a response."
        case .completed: "This candidate completed without a response."
        }
    }

    private func visibleSectionID(from positions: [String: CGFloat]) -> String? {
        guard !positions.isEmpty else { return nil }
        let candidates = positions.filter { $0.value <= 120 }
        return candidates.max(by: { $0.value < $1.value })?.key
            ?? positions.min(by: { abs($0.value) < abs($1.value) })?.key
    }
}

private struct FocusReaderSection: View {
    let section: MarkdownDocumentSection

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let headingMarkdown = section.headingMarkdown, !headingMarkdown.isEmpty {
                MarkdownResponseText(markdown: headingMarkdown)
                    .font(section.level <= 1 ? .title2.weight(.semibold) : .title3.weight(.semibold))
            }

            if !section.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownResponseText(markdown: section.bodyMarkdown)
            } else if section.headingMarkdown == nil {
                MarkdownResponseText(markdown: section.markdown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownResponseText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownResponseBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownResponseBlock) -> some View {
        switch block {
        case .paragraph(let value):
            MarkdownInlineText(markdown: value)
        case .unorderedList(let values):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•")
                        MarkdownInlineText(markdown: value)
                    }
                }
            }
        case .orderedList(let values):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        MarkdownInlineText(markdown: value)
                    }
                }
            }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 7)
                }
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct MarkdownInlineText: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: markdown) {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum MarkdownResponseBlock {
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case code(language: String, value: String)

    static func parse(_ markdown: String) -> [Self] {
        var blocks: [Self] = []
        var paragraphLines: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [String] = []
        var codeLanguage = ""
        var codeLines: [String] = []
        var fenceMarker: Character?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushLists() {
            if !unorderedItems.isEmpty {
                blocks.append(.unorderedList(unorderedItems))
                unorderedItems.removeAll(keepingCapacity: true)
            }
            if !orderedItems.isEmpty {
                blocks.append(.orderedList(orderedItems))
                orderedItems.removeAll(keepingCapacity: true)
            }
        }

        func flushCode() {
            blocks.append(.code(language: codeLanguage, value: codeLines.joined(separator: "\n")))
            codeLanguage = ""
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                if trimmed.hasPrefix(String(repeating: String(marker), count: 3)) {
                    fenceMarker = nil
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                flushLists()
                fenceMarker = trimmed.first
                let markerLength = trimmed.prefix(while: { $0 == fenceMarker }).count
                codeLanguage = String(trimmed.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
                codeLines.removeAll(keepingCapacity: true)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushLists()
                continue
            }

            if let item = listItem(in: trimmed, marker: "-"), !item.isEmpty {
                flushParagraph()
                if !orderedItems.isEmpty { flushLists() }
                unorderedItems.append(item)
                continue
            }
            if let item = listItem(in: trimmed, marker: "*"), !item.isEmpty {
                flushParagraph()
                if !orderedItems.isEmpty { flushLists() }
                unorderedItems.append(item)
                continue
            }
            if let item = listItem(in: trimmed, marker: "+"), !item.isEmpty {
                flushParagraph()
                if !orderedItems.isEmpty { flushLists() }
                unorderedItems.append(item)
                continue
            }
            if let item = orderedListItem(in: trimmed), !item.isEmpty {
                flushParagraph()
                if !unorderedItems.isEmpty { flushLists() }
                orderedItems.append(item)
                continue
            }

            if !unorderedItems.isEmpty || !orderedItems.isEmpty {
                flushLists()
            }
            paragraphLines.append(trimmed)
        }

        if fenceMarker != nil {
            flushCode()
        } else {
            flushParagraph()
            flushLists()
        }
        return blocks
    }

    private static func listItem(in line: String, marker: Character) -> String? {
        let prefix = "\(marker) "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func orderedListItem(in line: String) -> String? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber {
            index += 1
        }
        guard index > 0, index + 1 < characters.count, characters[index] == "." || characters[index] == ")", characters[index + 1] == " " else { return nil }
        return String(characters[(index + 2)...]).trimmingCharacters(in: .whitespaces)
    }
}

private struct FocusReaderComparison: View {
    let activeLane: LanePresentation
    let pinnedLane: LanePresentation
    let activeTitle: String
    let pinnedTitle: String
    let isWide: Bool
    @Binding var activeSelectedSectionID: String?
    @Binding var activeScrollTargetID: String?
    let onUnpin: () -> Void

    private var activeSections: [MarkdownDocumentSection] {
        MarkdownOutlineParser.sections(in: activeLane.output)
    }

    private var pinnedSections: [MarkdownDocumentSection] {
        MarkdownOutlineParser.sections(in: pinnedLane.output)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Pinned comparison", systemImage: "rectangle.split.2x1")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Unpin", systemImage: "pin.slash", action: onUnpin)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Unpin \(pinnedTitle) from comparison")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.28))

            Divider()

            if isWide {
                HStack(spacing: 0) {
                    comparisonPane(
                        lane: activeLane,
                        title: activeTitle,
                        sections: activeSections,
                        selectedSectionID: $activeSelectedSectionID,
                        scrollTargetID: $activeScrollTargetID
                    )
                    Divider()
                    comparisonPane(
                        lane: pinnedLane,
                        title: pinnedTitle,
                        sections: pinnedSections,
                        selectedSectionID: .constant(nil),
                        scrollTargetID: .constant(nil)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        comparisonPane(
                            lane: activeLane,
                            title: activeTitle,
                            sections: activeSections,
                            selectedSectionID: $activeSelectedSectionID,
                            scrollTargetID: $activeScrollTargetID
                        )
                        .frame(height: 340)
                        Divider()
                        comparisonPane(
                            lane: pinnedLane,
                            title: pinnedTitle,
                            sections: pinnedSections,
                            selectedSectionID: .constant(nil),
                            scrollTargetID: .constant(nil)
                        )
                        .frame(height: 340)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comparisonPane(
        lane: LanePresentation,
        title: String,
        sections: [MarkdownDocumentSection],
        selectedSectionID: Binding<String?>,
        scrollTargetID: Binding<String?>
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                LaneStatusBadge(state: lane.state)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.background)

            Divider()

            FocusReaderDocument(
                lane: lane,
                sections: sections,
                selectedSectionID: selectedSectionID,
                scrollTargetID: scrollTargetID
            )
        }
    }
}

private struct BlindVerdictInspector: View {
    @Bindable var store: JBenchAppStore
    let lane: LanePresentation
    let candidateTitle: String
    @Binding var pinnedLaneID: UUID?

    private var isPinned: Bool { pinnedLaneID == lane.id }
    private var hasSelection: Bool { store.winningLaneID == lane.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Select \(candidateTitle)")
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(statusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    LaneStatusBadge(state: lane.state)
                }

                Text("Choose the winner for this run. You can add a note to explain why this response won.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Why this response won (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Add a note about why this response is the best…", text: $store.reviewNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...7)
                        .onChange(of: store.reviewNote) { _, note in
                            if note.count > 500 {
                                store.reviewNote = String(note.prefix(500))
                            }
                        }
                    Text("\(store.reviewNote.count) / 500")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Button {
                    store.winningLaneID = lane.id
                } label: {
                    Label(hasSelection ? "Selected \(candidateTitle)" : "Select \(candidateTitle)", systemImage: hasSelection ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    pinnedLaneID = isPinned ? nil : lane.id
                } label: {
                    Label(isPinned ? "Pinned for comparison" : "Pin for comparison", systemImage: isPinned ? "pin.fill" : "pin")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text(isPinned ? "Pinned in this review. Switch candidates to compare this response with the active candidate." : "Pin this response to compare it with another candidate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                verdictActions
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var verdictActions: some View {
        if store.isRevealOn {
            if store.section == .newRun {
                Button {
                    store.viewActiveRunInHistory()
                } label: {
                    Label("View in History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)

                Button {
                    store.startNewRun()
                } label: {
                    Label("Start New Run", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(store.isBackgroundRunActive)
            }

            Button("Update verdict") { store.saveManualVerdict() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(store.winningLaneID == nil)
        } else {
            Button("Skip verdict and reveal") { store.skipManualVerdict() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

            Button("Save manual verdict") { store.saveManualVerdict() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(store.winningLaneID == nil)
        }
    }

    private var statusDescription: String {
        switch lane.state {
        case .queued: "Waiting to start"
        case .starting: "Starting response"
        case .running: lane.output.isEmpty ? "Generating response" : "Streaming response"
        case .waitingForApproval: "Waiting for your approval"
        case .completed: "Response complete"
        case .failed: "Candidate failed"
        case .timedOut: "Candidate timed out"
        case .cancelled: "Candidate cancelled"
        case .interrupted: "Run interrupted"
        }
    }
}

private struct FocusReaderSectionPositionKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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

struct LaneStatusBadge: View {
    let state: AgentRunState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .running, .starting:
                ProgressView()
                    .controlSize(.mini)
                Text("Running")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            case .queued:
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .waitingForApproval:
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Approval needed")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            case .failed, .timedOut:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(state == .timedOut ? "Timed Out" : "Failed")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            case .cancelled, .interrupted:
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(state == .interrupted ? "Interrupted" : "Cancelled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(backgroundColor, in: Capsule())
        .overlay {
            Capsule().strokeBorder(borderColor, lineWidth: 0.5)
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .running, .starting: Color.blue.opacity(0.1)
        case .completed: Color.green.opacity(0.1)
        case .waitingForApproval: Color.orange.opacity(0.12)
        case .failed, .timedOut: Color.red.opacity(0.1)
        case .cancelled, .interrupted, .queued: Color.secondary.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch state {
        case .running, .starting: Color.blue.opacity(0.3)
        case .completed: Color.green.opacity(0.3)
        case .waitingForApproval: Color.orange.opacity(0.3)
        case .failed, .timedOut: Color.red.opacity(0.3)
        case .cancelled, .interrupted, .queued: Color.secondary.opacity(0.2)
        }
    }
}
