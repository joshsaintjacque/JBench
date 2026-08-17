@preconcurrency import Foundation
import Darwin

/// A small, prompt-free app-server session used only for discovery. It is separate
/// from run sessions so discovery cannot acquire a benchmark attempt's process.
actor CodexDiscoveryProbe {
    private let executableURL: URL
    private let clientName: String
    private let clientVersion: String
    private let timeout: Duration
    private let shutdownGrace: Duration
    private let processIdentityProvider: @Sendable (Int32) -> OwnedProcessIdentity?
    private var process: Process?
    private var processIdentity: OwnedProcessIdentity?
    private var ownsProcessGroup = false
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var accountResult: [String: Any]?
    private var modelListJSON: String?
    private var continuation: CheckedContinuation<HarnessDiscoveryResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(
        executableURL: URL,
        clientName: String,
        clientVersion: String,
        timeout: Duration = .seconds(15),
        shutdownGrace: Duration = .seconds(1),
        processIdentityProvider: @escaping @Sendable (Int32) -> OwnedProcessIdentity? = OwnedProcessService.identity(for:)
    ) {
        self.executableURL = executableURL
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.timeout = timeout
        self.shutdownGrace = shutdownGrace
        self.processIdentityProvider = processIdentityProvider
    }

    func run() async throws -> HarnessDiscoveryResult {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation: continuation)
        }
    }

    private func start(continuation: CheckedContinuation<HarnessDiscoveryResult, Error>) {
        self.continuation = continuation
        let process = Process()
        let command = OwnedProcessLauncher.command(executable: executableURL, arguments: ["app-server", "--stdio"])
        process.executableURL = command.executable
        process.arguments = command.arguments
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        self.process = process
        self.input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data: data) }
        }
        process.terminationHandler = { [weak self] ended in
            Task { await self?.terminated(status: ended.terminationStatus) }
        }
        do {
            try process.run()
            guard let identity = processIdentityProvider(process.processIdentifier) else {
                finish(throwing: JBenchCoreError.storage("Could not establish ownership of the Codex discovery process. Cleanup is incomplete; no signal was sent."))
                return
            }
            processIdentity = identity
            ownsProcessGroup = OwnedProcessLauncher.ownsProcessGroup(process.processIdentifier)
            scheduleTimeout()
            try send(.request(id: 1, method: "initialize", params: CodexWireRequest.initializeParams(clientName: clientName, clientVersion: clientVersion)))
        } catch {
            finish(throwing: JBenchCoreError.storage("Could not launch Codex app-server for discovery at \(executableURL.path): \(error.localizedDescription)"))
        }
    }

    private func receive(data: Data) {
        guard !didFinish else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty,
                  let root = CodexWireJSON.object(line) else { continue }
            handle(root: root, rawJSON: line)
        }
    }

    private func handle(root: [String: Any], rawJSON: String) {
        guard let id = CodexWireJSON.int(root["id"]) else { return }
        if root["error"] != nil {
            finish(throwing: JBenchCoreError.storage(CodexWireJSON.errorMessage(root) ?? "Codex app-server discovery request failed."))
            return
        }
        switch id {
        case 1:
            try? send(.notification(method: "initialized"))
            try? send(.request(id: 2, method: "account/read", params: [:]))
            try? send(.request(id: 3, method: "model/list", params: [:]))
        case 2:
            accountResult = root
            completeIfReady()
        case 3:
            modelListJSON = rawJSON
            completeIfReady()
        default:
            break
        }
    }

    private func completeIfReady() {
        guard accountResult != nil, let modelListJSON else { return }
        let authenticationStatus = Self.authenticationStatus(from: accountResult!)
        finish(returning: HarnessDiscoveryResult(
            authenticationStatus: authenticationStatus,
            diagnosticMessage: authenticationStatus == .ready ? nil : "Codex app-server did not report an active account.",
            models: CodexAppServerAdapter.catalog(fromModelListJSON: modelListJSON)
        ))
    }

    private func send(_ message: CodexWireRequest) throws {
        guard let input, !didFinish else { throw JBenchCoreError.storage("Codex discovery session has ended.") }
        let data = try JSONSerialization.data(withJSONObject: message.object, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    private func terminated(status: Int32) {
        if !didFinish { finish(throwing: JBenchCoreError.storage("Codex app-server discovery exited with status \(status).")) }
    }

    private func finish(returning result: HarnessDiscoveryResult) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        input?.closeFile()
        continuation?.resume(returning: result)
        continuation = nil
        scheduleShutdown()
    }

    private func finish(throwing error: Error) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        input?.closeFile()
        continuation?.resume(throwing: error)
        continuation = nil
        scheduleShutdown()
    }

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timedOut()
        }
    }

    private func timedOut() async {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask = nil
        input?.closeFile()
        let cleanup = await stopOwnedProcess()
        continuation?.resume(throwing: JBenchCoreError.storage("Codex app-server discovery timed out after \(timeout). \(cleanup)"))
        continuation = nil
    }

    private func scheduleShutdown() {
        Task {
            _ = await self.stopOwnedProcess()
        }
    }

    /// Stops only this probe's launched process or its dedicated owned group.
    /// It never signals a process after the recorded leader identity has changed.
    private func stopOwnedProcess() async -> String {
        guard let process else { return "No Codex discovery process was started." }
        let pid = process.processIdentifier
        guard pid > 0 else { return "Codex discovery process had no valid PID." }
        let groupRuns = ownsProcessGroup && OwnedProcessLauncher.groupIsRunning(pid)
        if !process.isRunning && !groupRuns {
            return "Codex discovery process had already exited."
        }

        guard let processIdentity else {
            return "Codex discovery cleanup is incomplete: process identity was unavailable; no signal was sent."
        }
        guard canSignalOwnedTarget(pid: pid, groupRuns: groupRuns) else {
            return "Codex discovery cleanup is incomplete: process identity could not be verified; no signal was sent."
        }

        if await waitForOwnedTreeExit(of: process, timeout: shutdownGrace) {
            return "Codex discovery process exited after stdin closed."
        }

        guard canSignalOwnedTarget(pid: pid, groupRuns: groupRuns) else {
            return "Codex discovery cleanup is incomplete: process identity changed before termination; no signal was sent."
        }
        if groupRuns {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        if await waitForOwnedTreeExit(of: process, timeout: shutdownGrace) {
            return groupRuns ? "Terminated the owned Codex discovery process group." : "Terminated the owned Codex discovery process."
        }

        guard canSignalOwnedTarget(pid: pid, groupRuns: groupRuns) else {
            return "Codex discovery cleanup is incomplete: process identity changed before forced termination; no signal was sent."
        }
        if groupRuns, OwnedProcessLauncher.groupIsRunning(pid) {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGKILL)
        } else if process.isRunning {
            _ = Darwin.kill(pid, SIGKILL)
        }
        let exited = await waitForOwnedTreeExit(of: process, timeout: shutdownGrace)
        return exited
            ? "Forced termination of the owned Codex discovery process completed."
            : "Codex discovery process did not exit after owned-process cleanup."
    }

    private func waitForOwnedTreeExit(of process: Process, timeout: Duration) async -> Bool {
        let pid = process.processIdentifier
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while (process.isRunning || OwnedProcessLauncher.groupIsRunning(pid)) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !process.isRunning && !OwnedProcessLauncher.groupIsRunning(pid)
    }

    /// A surviving dedicated group remains owned after its leader exits. A readable
    /// but different leader identity is a reused PID and must never be signaled.
    private func canSignalOwnedTarget(pid: Int32, groupRuns: Bool) -> Bool {
        guard let processIdentity else { return false }
        guard let currentIdentity = processIdentityProvider(pid) else { return groupRuns }
        return currentIdentity == processIdentity
    }

    private nonisolated static func authenticationStatus(from response: [String: Any]) -> AuthenticationStatus {
        let result = response["result"] as? [String: Any] ?? [:]
        if let authenticated = result["authenticated"] as? Bool { return authenticated ? .ready : .missing }
        if let account = result["account"] {
            return account is NSNull ? .missing : .ready
        }
        if result["email"] != nil || result["plan"] != nil { return .ready }
        return .unknown
    }
}
