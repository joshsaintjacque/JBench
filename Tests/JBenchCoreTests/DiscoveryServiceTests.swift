import Foundation
import Testing
@testable import JBenchCore

private struct FixtureAdapter: HarnessDiscoveryAdapter {
    let harness: HarnessKind
    let result: HarnessDiscoveryResult
    func discover(executable: URL) async throws -> HarnessDiscoveryResult { result }
}

@Test func executableResolutionUsesOverrideThenPathThenKnownLocation() {
    let known = "/opt/homebrew/bin/codex"
    let resolver = ExecutableResolver(pathEnvironment: "/fixture/bin", fileExists: { path in
        path == "/override/codex" || path == "/fixture/bin/codex" || path == known
    })
    #expect(resolver.resolve(harness: .codex, override: "/override/codex")?.source == .overrideValue)
    #expect(resolver.resolve(harness: .codex)?.source == .path)
    let knownOnly = ExecutableResolver(pathEnvironment: "", fileExists: { $0 == known })
    #expect(knownOnly.resolve(harness: .codex)?.source == .knownLocation)
}

@Test func discoveryPreservesNativeReasoningValuesAndReportsDiagnostics() async {
    let entry = ModelCatalogEntry(harness: .codex, nativeModelID: "sol", displayName: "Sol", nativeReasoningValues: ["low", "high", "x-native"], discoverySource: "fixture")
    let adapter = FixtureAdapter(harness: .codex, result: .init(version: "0.1-test", authenticationStatus: .ready, models: [entry]))
    let resolver = ExecutableResolver(pathEnvironment: "/fixture", fileExists: { $0 == "/fixture/codex" })
    let service = DiscoveryService(resolver: resolver, adapters: [.codex: adapter])
    let installations = await service.discover([.codex])
    #expect(installations.first?.version == "0.1-test")
    #expect(installations.first?.authenticationStatus == .ready)
    #expect(await service.catalog(for: .codex).first?.nativeReasoningValues == ["low", "high", "x-native"])
}

@Test func missingExecutableDoesNotExposeSecrets() async {
    let service = DiscoveryService(resolver: ExecutableResolver(pathEnvironment: "", fileExists: { _ in false }))
    let installation = await service.discover([.openCode]).first
    #expect(installation?.authenticationStatus == .missing)
    #expect(installation?.executablePath == "")
    #expect(installation?.diagnosticMessage?.contains("not found") == true)
}

@Test func catalogCombinesCachedAndCustomEntriesWithoutNormalizingValues() async throws {
    let cached = ModelCatalogEntry(harness: .openCode, nativeModelID: "deepseek-v4", nativeReasoningValues: ["max"], discoverySource: "cache")
    let custom = ModelCatalogEntry(harness: .openCode, nativeModelID: "local", nativeReasoningValues: ["whatever-highest"], discoverySource: "custom", availability: .customNotVerified)
    let service = DiscoveryService(settings: .init(cachedCatalog: [cached], customModels: [custom]))
    let catalog = await service.catalog(for: .openCode)
    #expect(catalog.map(\.nativeModelID) == ["deepseek-v4", "local"])
    #expect(catalog.last?.nativeReasoningValues == ["whatever-highest"])
}

@Test func presetStoreValidatesTwoToSixAndUniqueNames() async throws {
    let agent = AgentConfiguration(harness: .codex, model: "sol")
    let store = PresetStore()
    do { _ = try await store.save(name: "Too few", agents: [agent]); Issue.record("Expected invalid count") }
    catch let error as PresetValidationError { #expect(error == .invalidAgentCount(1)) }
    _ = try await store.save(name: "Daily", agents: [agent, agent])
    do { _ = try await store.save(name: "daily", agents: [agent, agent]); Issue.record("Expected duplicate name") }
    catch let error as PresetValidationError { #expect(error == .duplicateName("daily")) }
    #expect(try await store.save(name: "  Team  ", agents: [agent, agent]).name == "Team")
}
