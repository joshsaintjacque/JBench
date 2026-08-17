import Foundation

/// A protocol-level result returned by a harness adapter during discovery.
/// The adapter owns all harness-specific wire details; this layer only stores
/// the native values exactly as reported.
public struct HarnessDiscoveryResult: Sendable, Equatable {
    public var version: String?
    public var authenticationStatus: AuthenticationStatus
    public var diagnosticMessage: String?
    public var models: [ModelCatalogEntry]

    public init(version: String? = nil, authenticationStatus: AuthenticationStatus = .unknown, diagnosticMessage: String? = nil, models: [ModelCatalogEntry] = []) {
        self.version = version
        self.authenticationStatus = authenticationStatus
        self.diagnosticMessage = diagnosticMessage
        self.models = models
    }
}

public protocol HarnessDiscoveryAdapter: Sendable {
    var harness: HarnessKind { get }
    func discover(executable: URL) async throws -> HarnessDiscoveryResult
}

public struct DiscoverySettings: Codable, Sendable, Equatable {
    public var executableOverrides: [HarnessKind: String]
    public var cachedCatalog: [ModelCatalogEntry]
    public var customModels: [ModelCatalogEntry]

    public init(executableOverrides: [HarnessKind: String] = [:], cachedCatalog: [ModelCatalogEntry] = [], customModels: [ModelCatalogEntry] = []) {
        self.executableOverrides = executableOverrides
        self.cachedCatalog = cachedCatalog
        self.customModels = customModels
    }
}

public struct ResolvedExecutable: Sendable, Equatable {
    public var harness: HarnessKind
    public var url: URL
    public var source: ExecutableResolutionSource
    public init(harness: HarnessKind, url: URL, source: ExecutableResolutionSource) {
        self.harness = harness; self.url = url; self.source = source
    }
}

public enum ExecutableResolutionSource: String, Sendable, Equatable { case overrideValue, path, knownLocation }

public struct ExecutableResolver: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var pathEnvironment: String

    public init(pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "", fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.pathEnvironment = pathEnvironment
        self.fileExists = fileExists
    }

    public func resolve(harness: HarnessKind, override: String? = nil) -> ResolvedExecutable? {
        guard harness != .fake else { return nil }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = URL(fileURLWithPath: override).standardizedFileURL.path
            if fileExists(path) { return ResolvedExecutable(harness: harness, url: URL(fileURLWithPath: path), source: .overrideValue) }
        }
        for directory in pathEnvironment.split(separator: ":").map(String.init) {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(commandName(for: harness)).path
            if fileExists(path) { return ResolvedExecutable(harness: harness, url: URL(fileURLWithPath: path), source: .path) }
        }
        for path in knownLocations(for: harness) where fileExists(path) {
            return ResolvedExecutable(harness: harness, url: URL(fileURLWithPath: path), source: .knownLocation)
        }
        return nil
    }

    private func commandName(for harness: HarnessKind) -> String { harness == .codex ? "codex" : "opencode" }
    private func knownLocations(for harness: HarnessKind) -> [String] {
        let command = commandName(for: harness)
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)", "/usr/bin/\(command)",
            "\(home)/.local/bin/\(command)", "\(home)/.opencode/bin/\(command)",
            "\(home)/.codex/bin/\(command)"
        ]
    }
}

public actor DiscoveryService {
    public private(set) var settings: DiscoverySettings
    private let resolver: ExecutableResolver
    private let adapters: [HarnessKind: any HarnessDiscoveryAdapter]
    private let cacheURL: URL?

    public init(settings: DiscoverySettings = .init(), resolver: ExecutableResolver = .init(), adapters: [HarnessKind: any HarnessDiscoveryAdapter] = [:], cacheURL: URL? = nil) {
        self.settings = settings; self.resolver = resolver; self.adapters = adapters; self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([ModelCatalogEntry].self, from: data) {
            self.settings.cachedCatalog = cached
        }
    }

    public func updateSettings(_ settings: DiscoverySettings) async throws {
        self.settings = settings
        try persistCache()
    }

    public func discover(_ harnesses: [HarnessKind] = [.codex, .openCode]) async -> [HarnessInstallation] {
        await withTaskGroup(of: HarnessInstallation?.self, returning: [HarnessInstallation].self) { group in
            for harness in harnesses where harness != .fake {
                group.addTask { await self.discoverOne(harness) }
            }
            var results: [HarnessInstallation] = []
            for await result in group { if let result { results.append(result) } }
            return results.sorted { $0.harness.rawValue < $1.harness.rawValue }
        }
    }

    public func catalog(for harness: HarnessKind) -> [ModelCatalogEntry] {
        let native = settings.cachedCatalog.filter { $0.harness == harness && $0.availability == .available }
        let custom = settings.customModels.filter { $0.harness == harness }
        return deduplicated(native + custom)
    }

    public func setNativeCatalog(_ entries: [ModelCatalogEntry], for harness: HarnessKind) throws {
        settings.cachedCatalog.removeAll { $0.harness == harness }
        settings.cachedCatalog.append(contentsOf: entries.filter { $0.harness == harness })
        try persistCache()
    }

    private func discoverOne(_ harness: HarnessKind) async -> HarnessInstallation? {
        guard let executable = resolver.resolve(harness: harness, override: settings.executableOverrides[harness]) else {
            return HarnessInstallation(harness: harness, executablePath: "", authenticationStatus: .missing, diagnosticMessage: "Executable was not found in the override, PATH, or known macOS locations.")
        }
        guard let adapter = adapters[harness] else {
            return HarnessInstallation(harness: harness, executablePath: executable.url.path, authenticationStatus: .unknown, diagnosticMessage: "Discovery adapter is not installed.")
        }
        do {
            let result = try await adapter.discover(executable: executable.url)
            settings.cachedCatalog.removeAll { $0.harness == harness }
            settings.cachedCatalog.append(contentsOf: result.models)
            try? persistCache()
            return HarnessInstallation(harness: harness, executablePath: executable.url.path, version: result.version, authenticationStatus: result.authenticationStatus, diagnosticMessage: result.diagnosticMessage, lastSuccessfulDiscoveryAt: .now)
        } catch {
            return HarnessInstallation(harness: harness, executablePath: executable.url.path, authenticationStatus: .unknown, diagnosticMessage: error.localizedDescription)
        }
    }

    private func deduplicated(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var seen = Set<String>(); return entries.filter { seen.insert("\($0.harness.rawValue)|\($0.nativeModelID)").inserted }
    }

    private func persistCache() throws {
        guard let cacheURL else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings.cachedCatalog).write(to: cacheURL, options: .atomic)
    }
}

public enum PresetValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyName, duplicateName(String), invalidAgentCount(Int)
    public var errorDescription: String? {
        switch self { case .emptyName: "Preset name cannot be empty."; case .duplicateName(let name): "A preset named \(name) already exists."; case .invalidAgentCount(let count): "Select two to six agents, not \(count)." }
    }
}

public actor PresetStore {
    public private(set) var presets: [Preset]
    public init(presets: [Preset] = []) { self.presets = presets }

    @discardableResult public func save(name: String, agents: [AgentConfiguration], replacing id: UUID? = nil) throws -> Preset {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw PresetValidationError.emptyName }
        guard (2...6).contains(agents.count) else { throw PresetValidationError.invalidAgentCount(agents.count) }
        if presets.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) { throw PresetValidationError.duplicateName(normalized) }
        let now = Date()
        let preset = try Preset(id: id ?? UUID(), name: normalized, agents: agents, createdAt: presets.first(where: { $0.id == id })?.createdAt ?? now, updatedAt: now)
        presets.removeAll { $0.id == preset.id }; presets.append(preset); presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }; return preset
    }

    public func remove(id: UUID) { presets.removeAll { $0.id == id } }
}
