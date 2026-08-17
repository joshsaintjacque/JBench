@preconcurrency import Foundation

/// A small, prompt-free app-server session used only for discovery. It is separate
/// from run sessions so discovery cannot acquire a benchmark attempt's process.
actor CodexDiscoveryProbe {
    private let executableURL: URL
    private let clientName: String
    private let clientVersion: String
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var accountResult: [String: Any]?
    private var modelListJSON: String?
    private var continuation: CheckedContinuation<HarnessDiscoveryResult, Error>?
    private var didFinish = false

    init(executableURL: URL, clientName: String, clientVersion: String) {
        self.executableURL = executableURL
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    func run() async throws -> HarnessDiscoveryResult {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation: continuation)
        }
    }

    private func start(continuation: CheckedContinuation<HarnessDiscoveryResult, Error>) {
        self.continuation = continuation
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
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
        input?.closeFile()
        continuation?.resume(returning: result)
        continuation = nil
        terminateAfterGrace()
    }

    private func finish(throwing error: Error) {
        guard !didFinish else { return }
        didFinish = true
        input?.closeFile()
        continuation?.resume(throwing: error)
        continuation = nil
        terminateAfterGrace()
    }

    private func terminateAfterGrace() {
        guard let process, process.isRunning else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { process.terminate() }
        }
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
