import Darwin
import Foundation

public struct OwnedProcessIdentity: Codable, Sendable, Hashable {
    public var processID: Int32
    /// The operating system start time, used to reject a reused PID.
    public var startTime: String
    public var command: String

    public init(processID: Int32, startTime: String, command: String) {
        self.processID = processID
        self.startTime = startTime
        self.command = command
    }

    public var serialized: String { "pid=\(processID);started=\(startTime);command=\(command)" }
}

public struct OwnedProcess: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var identity: OwnedProcessIdentity
    public var registeredAt: Date

    public init(id: UUID = UUID(), label: String, identity: OwnedProcessIdentity, registeredAt: Date = .now) {
        self.id = id
        self.label = label
        self.identity = identity
        self.registeredAt = registeredAt
    }
}

public enum OwnedProcessTermination: Sendable, Hashable {
    case terminatedGracefully
    case terminatedWithFallback
    case fallbackFailed
    case alreadyExited
    case identityMismatch
    case notRegistered
}

public enum OwnedProcessError: Error, LocalizedError, Sendable, Equatable {
    case executableMissing(String)
    case identityUnavailable(Int32)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): "Cannot launch a missing executable: \(path)"
        case .identityUnavailable(let pid): "Cannot establish ownership for process \(pid)."
        }
    }
}

/// Tracks only processes started by this service. PID-only termination is never used.
public actor OwnedProcessService {
    private var owned: [UUID: OwnedProcess] = [:]

    public init() {}

    @discardableResult
    public func launch(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        label: String
    ) throws -> OwnedProcess {
        let executable = executable.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OwnedProcessError.executableMissing(executable.path)
        }
        let process = Process()
        let command = OwnedProcessLauncher.command(executable: executable, arguments: arguments)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = currentDirectory?.standardizedFileURL
        try process.run()
        guard let identity = Self.identity(for: process.processIdentifier) else {
            process.terminate()
            throw OwnedProcessError.identityUnavailable(process.processIdentifier)
        }
        let record = OwnedProcess(label: label, identity: identity)
        owned[record.id] = record
        return record
    }

    /// Used after the caller starts a process itself. The caller must supply the identity observed immediately after launch.
    @discardableResult
    public func registerLaunchedProcess(label: String, identity: OwnedProcessIdentity) -> OwnedProcess {
        let record = OwnedProcess(label: label, identity: identity)
        owned[record.id] = record
        return record
    }

    public func records() -> [OwnedProcess] { owned.values.sorted { $0.registeredAt < $1.registeredAt } }

    public func terminate(_ id: UUID) async -> OwnedProcessTermination {
        guard let record = owned[id] else { return .notRegistered }
        let pid = record.identity.processID
        let ownsGroup = OwnedProcessLauncher.ownsProcessGroup(pid) || OwnedProcessLauncher.groupIsRunning(pid)
        guard let actual = Self.identity(for: pid) else {
            if ownsGroup, OwnedProcessLauncher.groupIsRunning(pid) {
                _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM)
                if await waitForTreeExit(record.identity, ownsGroup: true, timeout: .seconds(5)) { owned[id] = nil; return .terminatedGracefully }
                _ = OwnedProcessLauncher.signalGroup(pid, SIGKILL)
                if await waitForTreeExit(record.identity, ownsGroup: true, timeout: .seconds(1)) { owned[id] = nil; return .terminatedWithFallback }
                return .fallbackFailed
            }
            owned[id] = nil
            return .alreadyExited
        }
        guard actual == record.identity else {
            // A PID may have been reused. Drop this stale ownership record without signaling it.
            owned[id] = nil
            return .identityMismatch
        }

        if ownsGroup { _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM) } else { _ = Darwin.kill(pid, SIGTERM) }
        if await waitForTreeExit(record.identity, ownsGroup: ownsGroup, timeout: .seconds(5)) {
            owned[id] = nil
            return .terminatedGracefully
        }

        guard Self.identity(for: pid) == record.identity || (ownsGroup && OwnedProcessLauncher.groupIsRunning(pid)) else {
            owned[id] = nil
            return .identityMismatch
        }
        if ownsGroup { _ = OwnedProcessLauncher.signalGroup(pid, SIGKILL) } else { _ = Darwin.kill(pid, SIGKILL) }
        if await waitForTreeExit(record.identity, ownsGroup: ownsGroup, timeout: .seconds(1)) {
            owned[id] = nil
            return .terminatedWithFallback
        }
        // Retain the record for a later explicit cleanup attempt and report the failed verification.
        return .fallbackFailed
    }

    public func terminateAll() async -> [UUID: OwnedProcessTermination] {
        let ids = Array(owned.keys)
        var results: [UUID: OwnedProcessTermination] = [:]
        for id in ids { results[id] = await terminate(id) }
        return results
    }

    public nonisolated static func identity(for processID: Int32) -> OwnedProcessIdentity? {
        guard processID > 0 else { return nil }
        guard let result = try? SystemCommand.run(
            executable: URL(filePath: "/bin/ps"),
            arguments: ["-o", "lstart=", "-o", "command=", "-p", String(processID)]
        ), result.status == 0 else { return nil }
        let line = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // `lstart` is fixed-width (24 chars), followed by the command string.
        let start = String(line.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = String(line.dropFirst(min(24, line.count))).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !start.isEmpty else { return nil }
        return OwnedProcessIdentity(processID: processID, startTime: start, command: command)
    }

    private func waitForExit(_ identity: OwnedProcessIdentity, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            guard let current = Self.identity(for: identity.processID) else { return true }
            guard current == identity else { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.identity(for: identity.processID) == nil
    }

    private func waitForTreeExit(_ identity: OwnedProcessIdentity, ownsGroup: Bool, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let leaderMatches = Self.identity(for: identity.processID) == identity
            let groupRuns = ownsGroup && OwnedProcessLauncher.groupIsRunning(identity.processID)
            if !leaderMatches && !groupRuns { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.identity(for: identity.processID) != identity
            && (!ownsGroup || !OwnedProcessLauncher.groupIsRunning(identity.processID))
    }
}
