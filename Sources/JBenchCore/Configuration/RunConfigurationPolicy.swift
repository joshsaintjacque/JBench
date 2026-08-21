import Foundation

/// Pure rules for selecting, validating, and preparing benchmark lanes.
///
/// The catalog follows `DiscoveryService.catalog(for:)`: available discovered
/// entries precede custom fallbacks, and duplicate native IDs retain the first
/// entry.
public struct RunConfigurationPolicy: Sendable {
    public static let minimumLaneCount = 2
    public static let maximumLaneCount = 6
    public static let unselectedModel = "Not selected"
    static let agyInteractiveApprovalMessage = "Antigravity editable lanes cannot use Ask for every approval in batch mode. Select Allow for attempt or Deny all."

    public init() {}

    /// Returns a user-facing error for combinations that a harness cannot run
    /// safely in the selected execution mode.
    public func validationError(for configurations: [AgentConfiguration], executionMode: ExecutionMode) -> String? {
        guard executionMode == .editable,
              configurations.contains(where: { $0.harness == .agy && $0.approvalPolicy == .askEveryTime }) else {
            return nil
        }
        return Self.agyInteractiveApprovalMessage
    }

    public func canRun(
        prompt: String,
        configurations: [AgentConfiguration],
        isDemoMode: Bool,
        isBackgroundRunActive: Bool,
        settings: DiscoverySettings
    ) -> Bool {
        // Multiple benchmark runs may be active at the same time. Other lifecycle
        // actions keep their own guards in the app store.
        _ = isBackgroundRunActive
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (Self.minimumLaneCount...Self.maximumLaneCount).contains(configurations.count) else {
            return false
        }

        if isDemoMode {
            return configurations.allSatisfy { $0.harness == .fake }
        }

        return configurations.allSatisfy { configuration in
            configuration.harness != .fake
                && catalog(for: configuration.harness, settings: settings)
                    .contains { $0.nativeModelID == configuration.model }
        }
    }

    public func catalog(for harness: HarnessKind, settings: DiscoverySettings) -> [ModelCatalogEntry] {
        guard harness != .fake else { return [] }
        let native = settings.cachedCatalog.filter { $0.harness == harness && $0.availability == .available }
        let custom = settings.customModels.filter { $0.harness == harness }
        var seen = Set<String>()
        return (native + custom).filter { seen.insert("\($0.harness.rawValue)|\($0.nativeModelID)").inserted }
    }

    public func models(for harness: HarnessKind, settings: DiscoverySettings) -> [String] {
        let values = catalog(for: harness, settings: settings).map(\.nativeModelID)
        return values.isEmpty ? [Self.unselectedModel] : values
    }

    public func reasoningValues(for configuration: AgentConfiguration, settings: DiscoverySettings) -> [String] {
        guard let model = catalog(for: configuration.harness, settings: settings)
            .first(where: { $0.nativeModelID == configuration.model }) else {
            return ["Default"]
        }
        return ["Default"] + model.nativeReasoningValues
    }

    public func normalized(_ configuration: AgentConfiguration, settings: DiscoverySettings) -> AgentConfiguration {
        var normalized = configuration
        let models = models(for: normalized.harness, settings: settings)
        if !models.contains(normalized.model) {
            normalized.model = models.first ?? Self.unselectedModel
        }
        let reasoning = reasoningValues(for: normalized, settings: settings)
        if let current = normalized.reasoning, !reasoning.contains(current) {
            normalized.reasoning = nil
        }
        return normalized
    }

    public func timeoutSeconds(timeoutMinutes: Int, usesNoTimeout: Bool) -> TimeInterval? {
        usesNoTimeout ? nil : TimeInterval(timeoutMinutes * 60)
    }

    public func applyingTimeout(
        to configurations: [AgentConfiguration],
        timeoutMinutes: Int,
        usesNoTimeout: Bool
    ) -> [AgentConfiguration] {
        let timeoutSeconds = timeoutSeconds(timeoutMinutes: timeoutMinutes, usesNoTimeout: usesNoTimeout)
        return configurations.map { configuration in
            var updated = configuration
            updated.timeoutSeconds = timeoutSeconds
            return updated
        }
    }
}
