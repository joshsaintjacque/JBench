import AppKit
import Foundation
import SwiftUI
import JBenchCore

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum RunPresentation: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case blindReview = "Blind Review"

    var id: Self { self }
}

struct LanePresentation: Identifiable, Hashable {
    let id: UUID
    var configuration: AgentConfiguration
    var state: AgentRunState
    var activity: String
    var output: String
    var observedModel: String?
    var observedReasoning: String?
    var elapsed: String
    var tokens: String
    var cost: String
    var approval: ApprovalRequest?
    var worktree: WorktreePresentation?
    var blindReviewOrder: Int

    init(
        id: UUID = UUID(),
        configuration: AgentConfiguration,
        state: AgentRunState = .completed,
        activity: String = "Response complete",
        output: String,
        observedModel: String? = nil,
        observedReasoning: String? = nil,
        elapsed: String = "—",
        tokens: String = "Unavailable",
        cost: String = "Unavailable",
        approval: ApprovalRequest? = nil,
        worktree: WorktreePresentation? = nil,
        blindReviewOrder: Int = 0
    ) {
        self.id = id
        self.configuration = configuration
        self.state = state
        self.activity = activity
        self.output = output
        self.observedModel = observedModel
        self.observedReasoning = observedReasoning
        self.elapsed = elapsed
        self.tokens = tokens
        self.cost = cost
        self.approval = approval
        self.worktree = worktree
        self.blindReviewOrder = blindReviewOrder
    }
}

struct WorktreePresentation: Hashable {
    var path: String
    var changedFiles: Int
    var status: String
    var diff: String
}

struct HistoryPresentation: Identifiable, Hashable {
    let id: UUID
    var title: String
    var date: Date
    var state: AggregateRunState
    var directory: String
    var mode: ExecutionMode
    var lanes: [LanePresentation]
    var prompt: String
}

struct HarnessDiagnostic: Identifiable, Hashable {
    let id: UUID
    var harness: HarnessKind
    var path: String
    var version: String
    var status: AuthenticationStatus
    var discovery: String
}

@MainActor
protocol JBenchRunService {
    func start(prompt: String, directory: String, mode: ExecutionMode, configurations: [AgentConfiguration])
    func cancel(laneID: UUID)
    func retry(laneID: UUID)
    func reply(_ reply: ApprovalReply, laneID: UUID)
}
