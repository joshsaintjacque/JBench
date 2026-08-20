import Testing
import Foundation
@testable import JBenchCore

struct AgyAdapterTests {
    @Test func defaultCatalogContainsGeminiAndClaudeModels() {
        let catalog = AgyAdapter.defaultCatalog()
        #expect(!catalog.isEmpty)
        #expect(catalog.contains { $0.nativeModelID == "gemini-3.7-flash" })
        #expect(catalog.contains { $0.nativeModelID == "gemini-3.7-pro" })
        #expect(catalog.contains { $0.nativeModelID == "claude-3-7-sonnet" })
        #expect(catalog.allSatisfy { $0.harness == .agy })
        #expect(catalog.allSatisfy { $0.nativeReasoningValues == ["low", "medium", "high"] })
    }

    @Test func supportsVerifiedReadOnlyCapability() async {
        let adapter = AgyAdapter()
        #expect(adapter.kind == .agy)
        #expect(adapter.supportsVerifiedReadOnly)
        let config = AgentConfiguration(harness: .agy, model: "gemini-3.7-flash")
        let capability = await adapter.readOnlyCapability(for: config)
        #expect(capability.mayStartReadOnlyRun)
    }

    @Test func discoveryResolvesAgyInstallation() async {
        let adapter = AgyAdapter()
        let result = try? await adapter.discover(executable: URL(fileURLWithPath: "/Users/joshs/.local/bin/agy"))
        if let result {
            #expect(result.version != nil)
            #expect(result.authenticationStatus == .ready)
            #expect(!result.models.isEmpty)
        }
    }

    @Test func runConfigurationPolicyAllowsAgyLanes() {
        let policy = RunConfigurationPolicy()
        let catalog = AgyAdapter.defaultCatalog()
        let settings = DiscoverySettings(cachedCatalog: catalog)

        let configs = [
            AgentConfiguration(harness: .agy, model: "gemini-3.7-flash", reasoning: "high"),
            AgentConfiguration(harness: .agy, model: "gemini-3.7-pro", reasoning: "low")
        ]

        let canRun = policy.canRun(
            prompt: "Refactor model",
            configurations: configs,
            isDemoMode: false,
            isBackgroundRunActive: false,
            settings: settings
        )

        #expect(canRun)
    }

    @Test func shutdownReturnsGracefulForInactiveAttempt() async {
        let adapter = AgyAdapter()
        let result = await adapter.shutdown(attemptID: UUID())
        #expect(result.completedGracefully)
    }

    @Test func rejectsInteractiveApprovalInEditableMode() async {
        let adapter = AgyAdapter(executablePath: "/usr/bin/true")
        let request = HarnessRequest(
            runID: UUID(),
            attemptID: UUID(),
            prompt: "Test",
            directoryPath: NSTemporaryDirectory(),
            executionMode: .editable,
            configuration: AgentConfiguration(harness: .agy, model: "gemini-3.7-flash", approvalPolicy: .askEveryTime)
        )
        let stream = await adapter.events(for: request)
        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
    }
}
