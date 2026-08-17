import Foundation

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case newRun
    case history
    case presets
    case settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .newRun: "New Run"
        case .history: "History"
        case .presets: "Presets"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .newRun: "plus.circle"
        case .history: "clock"
        case .presets: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}
