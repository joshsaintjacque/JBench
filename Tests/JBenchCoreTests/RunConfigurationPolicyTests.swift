import Foundation
import Testing
@testable import JBenchCore

@Test func runConfigurationPolicyRejectsInteractiveAgyApprovalOnlyForEditableRuns() {
    let policy = RunConfigurationPolicy()
    let agy = AgentConfiguration(harness: .agy, model: "gemini-3.7-flash", approvalPolicy: .askEveryTime)

    #expect(policy.validationError(for: [agy], executionMode: .editable) == RunConfigurationPolicy.agyInteractiveApprovalMessage)
    #expect(policy.validationError(for: [agy], executionMode: .readOnly) == nil)
    #expect(policy.validationError(for: [
        agy,
        AgentConfiguration(harness: .agy, model: "gemini-3.7-pro", approvalPolicy: .allowForAttempt)
    ], executionMode: .editable) == RunConfigurationPolicy.agyInteractiveApprovalMessage)
    #expect(policy.validationError(for: [
        AgentConfiguration(harness: .agy, model: "gemini-3.7-flash", approvalPolicy: .allowForAttempt),
        AgentConfiguration(harness: .agy, model: "gemini-3.7-pro", approvalPolicy: .denyAll)
    ], executionMode: .editable) == nil)
}

@Test func runConfigurationPolicyValidatesPromptLaneCountAndAvailability() {
    let policy = RunConfigurationPolicy()
    let settings = DiscoverySettings(cachedCatalog: [
        .init(harness: .codex, nativeModelID: "sol", discoverySource: "fixture")
    ])
    let lanes = [
        AgentConfiguration(harness: .codex, model: "sol"),
        AgentConfiguration(harness: .codex, model: "sol")
    ]

    #expect(policy.canRun(prompt: "Compare the approaches", configurations: lanes, isDemoMode: false, isBackgroundRunActive: false, settings: settings))
    #expect(!policy.canRun(prompt: "  \n", configurations: lanes, isDemoMode: false, isBackgroundRunActive: false, settings: settings))
    #expect(!policy.canRun(prompt: "Compare", configurations: Array(lanes.prefix(1)), isDemoMode: false, isBackgroundRunActive: false, settings: settings))
    #expect(!policy.canRun(prompt: "Compare", configurations: Array(repeating: lanes[0], count: 7), isDemoMode: false, isBackgroundRunActive: false, settings: settings))
    #expect(!policy.canRun(prompt: "Compare", configurations: lanes, isDemoMode: false, isBackgroundRunActive: true, settings: settings))
    #expect(!policy.canRun(prompt: "Compare", configurations: [
        AgentConfiguration(harness: .codex, model: "missing"),
        AgentConfiguration(harness: .codex, model: "sol")
    ], isDemoMode: false, isBackgroundRunActive: false, settings: settings))
}

@Test func runConfigurationPolicyAllowsOnlyFakeLanesInDemoMode() {
    let policy = RunConfigurationPolicy()
    let lanes = [
        AgentConfiguration(harness: .fake, model: "Provider-free sample"),
        AgentConfiguration(harness: .fake, model: "Provider-free alternate")
    ]

    #expect(policy.canRun(prompt: "A prompt", configurations: lanes, isDemoMode: true, isBackgroundRunActive: false, settings: .init()))
    #expect(!policy.canRun(prompt: "A prompt", configurations: [
        lanes[0],
        AgentConfiguration(harness: .codex, model: "sol")
    ], isDemoMode: true, isBackgroundRunActive: false, settings: .init()))
}

@Test func runConfigurationPolicyUsesDiscoveryCatalogAndCustomFallbacks() {
    let policy = RunConfigurationPolicy()
    let settings = DiscoverySettings(
        cachedCatalog: [
            .init(harness: .codex, nativeModelID: "sol", nativeReasoningValues: ["low", "high"], discoverySource: "discovered"),
            .init(harness: .codex, nativeModelID: "stale", discoverySource: "cache", availability: .stale),
            .init(harness: .codex, nativeModelID: "sol", discoverySource: "duplicate")
        ],
        customModels: [
            .init(harness: .codex, nativeModelID: "local", nativeReasoningValues: ["maximum"], discoverySource: "custom", availability: .customNotVerified),
            .init(harness: .codex, nativeModelID: "sol", discoverySource: "custom duplicate", availability: .customNotVerified)
        ]
    )

    #expect(policy.catalog(for: .codex, settings: settings).map(\.nativeModelID) == ["sol", "local"])
    #expect(policy.models(for: .fake, settings: settings) == [RunConfigurationPolicy.unselectedModel])
    #expect(policy.reasoningValues(for: .init(harness: .codex, model: "local"), settings: settings) == ["Default", "maximum"])
}

@Test func runConfigurationPolicyFallsBackModelsAndClearsStaleReasoning() {
    let policy = RunConfigurationPolicy()
    let settings = DiscoverySettings(cachedCatalog: [
        .init(harness: .codex, nativeModelID: "sol", nativeReasoningValues: ["low", "high"], discoverySource: "fixture")
    ])

    let fallback = policy.normalized(.init(harness: .codex, model: "removed", reasoning: "maximum"), settings: settings)
    #expect(fallback.model == "sol")
    #expect(fallback.reasoning == nil)

    let staleReasoning = policy.normalized(.init(harness: .codex, model: "sol", reasoning: "maximum"), settings: settings)
    #expect(staleReasoning.model == "sol")
    #expect(staleReasoning.reasoning == nil)
}

@Test func runConfigurationPolicyAppliesTimeoutOrNoTimeoutToEveryLane() {
    let policy = RunConfigurationPolicy()
    let lanes = [
        AgentConfiguration(harness: .fake, model: "one", timeoutSeconds: 1),
        AgentConfiguration(harness: .fake, model: "two", timeoutSeconds: 2)
    ]

    #expect(policy.applyingTimeout(to: lanes, timeoutMinutes: 15, usesNoTimeout: false).map(\.timeoutSeconds) == [900, 900])
    #expect(policy.applyingTimeout(to: lanes, timeoutMinutes: 15, usesNoTimeout: true).allSatisfy { $0.timeoutSeconds == nil })
}
