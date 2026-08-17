@preconcurrency import Foundation
import Darwin

/// A per-attempt adapter for Codex app-server's newline-delimited JSON protocol.
///
/// This adapter starts only the process it owns. Every native message is retained in
/// `AdapterEvent.rawJSON`; unknown notification fields are intentionally not decoded
/// into a lossy intermediate model.
public actor CodexAppServerAdapter: HarnessAdapter, HarnessDiscoveryAdapter {
    public nonisolated let kind: HarnessKind = .codex
    public nonisolated let harness: HarnessKind = .codex
    public nonisolated let supportsVerifiedReadOnly = true

    private let executableURL: URL
    private let clientName: String
    private let clientVersion: String
    /// Test-only seam for proving that process termination never races queued stdout.
    private let stdoutProcessingDelay: Duration
    private var sessions: [UUID: AttemptSession] = [:]

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/local/bin/codex"),
        clientName: String = "JBench",
        clientVersion: String = "1.0"
    ) {
        self.init(
            executableURL: executableURL,
            clientName: clientName,
            clientVersion: clientVersion,
            stdoutProcessingDelay: .zero
        )
    }

    init(
        executableURL: URL,
        clientName: String,
        clientVersion: String,
        stdoutProcessingDelay: Duration
    ) {
        self.executableURL = executableURL
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.stdoutProcessingDelay = stdoutProcessingDelay
    }

    public func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                await self?.start(request: request, continuation: continuation)
            }
        }
    }

    public func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {
        guard let session = sessions[attemptID], let nativeID = session.nativeApprovalIDs.removeValue(forKey: request.id) else {
            throw JBenchCoreError.unsupportedApproval
        }
        let decision: String = switch reply {
        case .approveOnce: "accept"
        case .approveForAttempt: "acceptForSession"
        case .decline: "decline"
        }
        try send(
            .response(id: nativeID, result: ["decision": decision]),
            to: session
        )
    }

    public func cancel(attemptID: UUID) async {
        _ = await shutdown(attemptID: attemptID)
    }

    /// Stops only the app-server process created for this attempt. It gives the
    /// server five seconds to exit after stdin closes, then uses SIGTERM and a
    /// final PID-bound SIGKILL fallback. It never signals an unrelated process.
    public func shutdown(attemptID: UUID) async -> HarnessShutdownResult {
        guard let session = sessions[attemptID] else { return .completed }
        defer { sessions[attemptID] = nil }
        sendInterrupt(to: session)
        finish(session: session, error: CancellationError(), terminateAfterGrace: false)
        if await waitForOwnedTreeExit(of: session.process, timeout: .seconds(5)) {
            return .init(completedGracefully: true, detail: "Codex app-server exited after stdin closed.")
        }
        let pid = session.process.processIdentifier
        guard session.process.isRunning || OwnedProcessLauncher.groupIsRunning(pid) else {
            return .init(completedGracefully: true, detail: "Codex app-server exited after stdin closed.")
        }
        if OwnedProcessLauncher.ownsProcessGroup(pid) || OwnedProcessLauncher.groupIsRunning(pid) {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM)
        } else {
            session.process.terminate()
        }
        if await waitForOwnedTreeExit(of: session.process, timeout: .seconds(1)) {
            return .init(completedGracefully: false, detail: "Codex app-server required SIGTERM fallback.")
        }
        if OwnedProcessLauncher.groupIsRunning(pid) {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGKILL)
        } else if session.process.isRunning, pid > 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
        let exited = await waitForOwnedTreeExit(of: session.process, timeout: .seconds(1))
        return .init(
            completedGracefully: false,
            detail: exited ? "Codex app-server required SIGKILL fallback." : "Codex app-server did not exit after SIGKILL fallback."
        )
    }

    /// Reads Codex's CLI version and then asks the app-server for account and model
    /// information. This sends no turn or prompt request.
    public func discover(executable: URL) async throws -> HarnessDiscoveryResult {
        let versionResult = try? SystemCommand.run(executable: executable, arguments: ["--version"])
        let version = versionResult?.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = CodexDiscoveryProbe(executableURL: executable, clientName: clientName, clientVersion: clientVersion)
        var result = try await probe.run()
        result.version = version?.isEmpty == false ? version : result.version
        return result
    }

    /// Translates a native model/list response to native, unnormalised catalog entries.
    /// The caller supplies the exact server response as retained evidence.
    public nonisolated static func catalog(fromModelListJSON rawJSON: String, catalogedAt: Date = .now) -> [ModelCatalogEntry] {
        guard let root = CodexWireJSON.object(rawJSON), let data = root["result"] else { return [] }
        let models = CodexWireJSON.objects(in: data, preferredKeys: ["models", "data"])
        return models.compactMap { model in
            guard let id = CodexWireJSON.string(model["id"]) ?? CodexWireJSON.string(model["model"]) else { return nil }
            let efforts = CodexWireJSON.strings(model["supportedReasoningEfforts"])
            return ModelCatalogEntry(
                harness: .codex,
                nativeModelID: id,
                displayName: CodexWireJSON.string(model["displayName"]),
                nativeReasoningValues: efforts,
                discoverySource: "Codex app-server model/list",
                catalogedAt: catalogedAt
            )
        }
    }

    private func start(
        request: HarnessRequest,
        continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    ) {
        guard sessions[request.attemptID] == nil else {
            continuation.finish(throwing: JBenchCoreError.storage("Codex attempt is already running."))
            return
        }

        let process = Process()
        let command = OwnedProcessLauncher.command(executable: executableURL, arguments: ["app-server", "--stdio"])
        process.executableURL = command.executable
        process.arguments = command.arguments
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let session = AttemptSession(
            attemptID: request.attemptID,
            request: request,
            process: process,
            input: standardInput.fileHandleForWriting,
            continuation: continuation
        )
        sessions[request.attemptID] = session

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let session, session.captureStdout(from: handle) else { return }
            Task { [weak self] in
                await self?.drainStdoutAfterConfiguredDelay(attemptID: request.attemptID)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveStandardError(data: data, attemptID: request.attemptID) }
        }
        process.terminationHandler = { [weak self] ended in
            Task { await self?.processTerminated(attemptID: request.attemptID, status: ended.terminationStatus) }
        }

        do {
            try process.run()
            let identity = OwnedProcessService.identity(for: process.processIdentifier)
            let ownership = ProcessOwnership(
                processID: process.processIdentifier,
                processIdentity: identity?.serialized ?? "pid=\(process.processIdentifier);identity=unavailable"
            )
            continuation.yield(.init(
                kind: .lifecycle,
                lifecycle: .init(ownership: ownership),
                rawJSON: CodexWireJSON.localEvidence("processStarted", attemptID: request.attemptID)
            ))
            continuation.yield(.init(kind: .started, rawJSON: CodexWireJSON.localEvidence("processStarted", attemptID: request.attemptID)))
            try send(.request(id: 1, method: "initialize", params: CodexWireRequest.initializeParams(clientName: clientName, clientVersion: clientVersion)), to: session)
        } catch {
            sessions[request.attemptID] = nil
            continuation.finish(throwing: JBenchCoreError.storage("Could not launch Codex app-server at \(executableURL.path): \(error.localizedDescription)"))
        }
    }

    private func drainStdoutAfterConfiguredDelay(attemptID: UUID) async {
        if stdoutProcessingDelay > .zero {
            try? await Task.sleep(for: stdoutProcessingDelay)
        }
        drainStdout(attemptID: attemptID)
    }

    private func drainStdout(attemptID: UUID) {
        guard let session = sessions[attemptID], !session.finished else { return }
        let data = session.takePendingStdout()
        guard !data.isEmpty else { return }
        session.stdoutBuffer.append(data)
        while let newline = session.stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = session.stdoutBuffer.prefix(upTo: newline)
            session.stdoutBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line, session: session)
        }
    }

    private func receiveStandardError(data: Data, attemptID: UUID) {
        guard let session = sessions[attemptID], !session.finished,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        session.continuation.yield(.init(kind: .activity, text: text, rawJSON: CodexWireJSON.localEvidence("stderr", text: text)))
    }

    private func handle(line: String, session: AttemptSession) {
        guard let root = CodexWireJSON.object(line) else {
            session.continuation.yield(.init(kind: .activity, text: "Received non-JSON Codex protocol output.", rawJSON: line))
            return
        }

        if let method = CodexWireJSON.string(root["method"]) {
            handleNotification(method: method, root: root, rawJSON: line, session: session)
            return
        }
        if root["id"] != nil {
            handleResponse(root: root, rawJSON: line, session: session)
        }
    }

    private func handleResponse(root: [String: Any], rawJSON: String, session: AttemptSession) {
        let id = CodexWireJSON.int(root["id"])
        if root["error"] != nil {
            let message = CodexWireJSON.errorMessage(root) ?? "Codex app-server rejected a request."
            session.continuation.yield(.init(kind: .failed, text: message, rawJSON: rawJSON))
            finish(session: session, error: nil, terminateAfterGrace: true)
            return
        }
        switch id {
        case 1:
            try? send(.notification(method: "initialized"), to: session)
            let params = CodexWireRequest.threadStartParams(for: session.request)
            try? send(.request(id: 2, method: "thread/start", params: params), to: session)
        case 2:
            session.threadID = CodexWireJSON.string(at: ["result", "thread", "id"], in: root)
                ?? CodexWireJSON.string(at: ["result", "id"], in: root)
            guard let threadID = session.threadID else {
                session.continuation.yield(.init(kind: .failed, text: "Codex app-server did not return a thread ID.", rawJSON: rawJSON))
                finish(session: session, error: nil, terminateAfterGrace: true)
                return
            }
            session.continuation.yield(.init(
                kind: .lifecycle,
                lifecycle: .init(protocolSessionID: threadID),
                rawJSON: rawJSON
            ))
            let turnID = session.nextRequestID()
            try? send(.request(id: turnID, method: "turn/start", params: CodexWireRequest.turnStartParams(for: session.request, threadID: threadID)), to: session)
        default:
            if let nativeTurnID = CodexWireJSON.string(at: ["result", "turn", "id"], in: root) ?? CodexWireJSON.string(at: ["result", "id"], in: root) {
                session.turnID = nativeTurnID
            }
            if let observed = CodexWireDecoder.observedSettings(from: root) {
                session.continuation.yield(.init(kind: .observedSettings, observed: observed, rawJSON: rawJSON))
            }
        }
    }

    private func handleNotification(method: String, root: [String: Any], rawJSON: String, session: AttemptSession) {
        if let nativeID = CodexWireJSON.requestID(root["id"]), CodexWireDecoder.isApprovalRequest(method: method) {
            if let decision = CodexWireRequest.automaticApprovalDecision(for: session.request.configuration.approvalPolicy) {
                do {
                    try send(.response(id: nativeID, result: ["decision": decision]), to: session)
                    session.continuation.yield(.init(kind: .activity, text: "Approved for this attempt.", rawJSON: rawJSON))
                } catch {
                    session.continuation.yield(.init(kind: .failed, text: "Could not reply to Codex approval request: \(error.localizedDescription)", rawJSON: rawJSON))
                    finish(session: session, error: nil, terminateAfterGrace: true)
                }
                return
            }
            let request = CodexWireDecoder.approval(from: root)
            session.nativeApprovalIDs[request.id] = nativeID
            session.continuation.yield(.init(kind: .approvalRequest, approval: request, rawJSON: rawJSON))
            return
        }

        for event in CodexWireDecoder.events(method: method, root: root, rawJSON: rawJSON) {
            session.continuation.yield(event)
            if event.kind == .completed || event.kind == .failed {
                finish(session: session, error: nil, terminateAfterGrace: true)
            }
        }
    }

    private func send(_ message: CodexWireRequest, to session: AttemptSession) throws {
        guard !session.finished else { throw JBenchCoreError.storage("Codex attempt has ended.") }
        let data = try JSONSerialization.data(withJSONObject: message.object, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try session.input.write(contentsOf: line)
    }

    private func sendInterrupt(to session: AttemptSession) {
        guard let turnID = session.turnID, !session.finished else { return }
        try? send(
            .request(
                id: session.nextRequestID(),
                method: "turn/interrupt",
                params: ["threadId": session.threadID ?? "", "turnId": turnID]
            ),
            to: session
        )
    }

    private func finish(session: AttemptSession, error: Error?, terminateAfterGrace: Bool) {
        guard !session.finished else { return }
        session.finished = true
        session.continuation.finish(throwing: error)
        session.input.closeFile()
        if terminateAfterGrace, session.process.isRunning {
            let process = session.process
            Task {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func processTerminated(attemptID: UUID, status: Int32) async {
        guard let session = sessions[attemptID] else { return }
        session.stdoutHandlerOff()
        if let output = session.process.standardOutput as? Pipe {
            session.stopAndCaptureRemainingStdout(from: output.fileHandleForReading)
        } else {
            session.stopCapturingStdout()
        }
        // The process cannot produce more stdout after termination. Capture every
        // remaining byte first, then decode the ordered buffer before classifying
        // an otherwise unexplained exit as a failure.
        drainStdout(attemptID: attemptID)
        if !session.finished {
            let detail = "Codex app-server ended with status \(status)."
            session.continuation.finish(throwing: JBenchCoreError.storage(detail))
        }
    }

    private func waitForExit(of process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func waitForOwnedTreeExit(of process: Process, timeout: Duration) async -> Bool {
        let pid = process.processIdentifier
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while (process.isRunning || OwnedProcessLauncher.groupIsRunning(pid)) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning && !OwnedProcessLauncher.groupIsRunning(pid)
    }
}

private final class AttemptSession: @unchecked Sendable {
    let attemptID: UUID
    let request: HarnessRequest
    let process: Process
    let input: FileHandle
    let continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    var stdoutBuffer = Data()
    var threadID: String?
    var turnID: String?
    var nativeApprovalIDs: [UUID: CodexRequestID] = [:]
    var requestCounter = 3
    var finished = false
    private let stdoutLock = NSLock()
    private var pendingStdout = Data()
    private var stdoutDrainScheduled = false
    private var stdoutCaptureStopped = false

    init(attemptID: UUID, request: HarnessRequest, process: Process, input: FileHandle, continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation) {
        self.attemptID = attemptID; self.request = request; self.process = process; self.input = input; self.continuation = continuation
    }

    func nextRequestID() -> Int {
        defer { requestCounter += 1 }
        return requestCounter
    }

    func stdoutHandlerOff() {
        if let output = process.standardOutput as? Pipe { output.fileHandleForReading.readabilityHandler = nil }
        if let error = process.standardError as? Pipe { error.fileHandleForReading.readabilityHandler = nil }
    }

    /// Captures output before scheduling actor work. The lock covers the pipe read
    /// so termination cannot close capture between the native read and enqueue.
    func captureStdout(from handle: FileHandle) -> Bool {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        guard !stdoutCaptureStopped else { return false }
        let data = handle.availableData
        guard !data.isEmpty else { return false }
        pendingStdout.append(data)
        guard !stdoutDrainScheduled else { return false }
        stdoutDrainScheduled = true
        return true
    }

    func stopAndCaptureRemainingStdout(from handle: FileHandle) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        stdoutCaptureStopped = true
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { return }
            pendingStdout.append(data)
        }
    }

    func stopCapturingStdout() {
        stdoutLock.lock()
        stdoutCaptureStopped = true
        stdoutLock.unlock()
    }

    func takePendingStdout() -> Data {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        let data = pendingStdout
        pendingStdout = Data()
        stdoutDrainScheduled = false
        return data
    }
}

enum CodexRequestID: Hashable {
    case integer(Int)
    case string(String)

    var value: Any { switch self { case .integer(let value): value; case .string(let value): value } }
}

enum CodexWireRequest {
    case request(id: Int, method: String, params: [String: Any])
    case notification(method: String)
    case response(id: CodexRequestID, result: [String: Any])

    var object: [String: Any] {
        switch self {
        case .request(let id, let method, let params): ["id": id, "method": method, "params": params]
        case .notification(let method): ["method": method, "params": [:]]
        case .response(let id, let result): ["id": id.value, "result": result]
        }
    }

    static func initializeParams(clientName: String, clientVersion: String) -> [String: Any] {
        ["clientInfo": ["name": clientName, "version": clientVersion], "capabilities": ["experimentalApi": true]]
    }

    static func threadStartParams(for request: HarnessRequest) -> [String: Any] {
        [
            "cwd": request.directoryPath,
            "model": request.configuration.model,
            "approvalPolicy": approvalPolicy(for: request.configuration.approvalPolicy),
            "sandbox": sandbox(for: request.executionMode)
        ]
    }

    static func turnStartParams(for request: HarnessRequest, threadID: String) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": request.prompt]],
            "model": request.configuration.model,
            "cwd": request.directoryPath,
            "approvalPolicy": approvalPolicy(for: request.configuration.approvalPolicy),
            "sandboxPolicy": ["type": sandbox(for: request.executionMode)]
        ]
        if let effort = request.configuration.reasoning { params["effort"] = effort }
        return params
    }

    private static func sandbox(for mode: ExecutionMode) -> String { mode == .readOnly ? "readOnly" : "workspaceWrite" }
    static func approvalPolicy(for policy: ApprovalPolicy) -> String {
        switch policy {
        case .askEveryTime, .allowForAttempt: "on-request"
        case .denyAll: "never"
        }
    }

    /// Codex still asks the client to resolve requests for an allowed attempt.
    /// Reply at the protocol layer so the UI stays unblocked.
    static func automaticApprovalDecision(for policy: ApprovalPolicy) -> String? {
        policy == .allowForAttempt ? "acceptForSession" : nil
    }
}

enum CodexWireDecoder {
    static func isApprovalRequest(method: String) -> Bool {
        let lowered = method.lowercased()
        return lowered.contains("approval") || lowered.contains("permission")
    }

    static func approval(from root: [String: Any]) -> ApprovalRequest {
        let params = root["params"] as? [String: Any] ?? [:]
        let category = CodexWireJSON.string(params["kind"]) ?? CodexWireJSON.string(params["category"]) ?? CodexWireJSON.string(root["method"])
        let target = CodexWireJSON.string(params["path"]) ?? CodexWireJSON.string(params["cwd"])
        let summary = CodexWireJSON.string(params["reason"])
            ?? CodexWireJSON.string(params["command"])
            ?? CodexWireJSON.string(params["description"])
            ?? "Codex requests \(category ?? "approval")."
        return ApprovalRequest(summary: summary, targetPath: target, permissionCategory: category)
    }

    static func events(method: String, root: [String: Any], rawJSON: String) -> [AdapterEvent] {
        let lower = method.lowercased()
        let params = root["params"] as? [String: Any] ?? [:]
        if lower == "thread/started" || lower == "turn/started" { return [.init(kind: .started, rawJSON: rawJSON)] }
        if lower.contains("agentmessage") && lower.contains("delta") {
            return [.init(kind: .outputDelta, text: CodexWireJSON.delta(in: params), rawJSON: rawJSON)]
        }
        if lower.contains("reasoning") && lower.contains("delta") || lower.contains("command") && lower.contains("delta") {
            return [.init(kind: .activity, text: CodexWireJSON.delta(in: params), rawJSON: rawJSON)]
        }
        if lower.contains("usage") || lower.contains("token") {
            return [.init(kind: .metrics, metrics: metrics(from: params), rawJSON: rawJSON)]
        }
        if lower.contains("rerouted") || lower.contains("model") && lower.contains("changed") {
            return [.init(kind: .observedSettings, observed: observedSettings(from: params) ?? .init(), rawJSON: rawJSON)]
        }
        if lower == "turn/completed" || lower == "turn/complete" {
            return [.init(kind: .completed, text: CodexWireJSON.string(params["message"]), rawJSON: rawJSON)]
        }
        if lower == "error" || lower.hasSuffix("/error") {
            return [.init(kind: .failed, text: CodexWireJSON.errorMessage(params) ?? "Codex app-server reported an error.", rawJSON: rawJSON)]
        }
        return [.init(kind: .activity, text: method, rawJSON: rawJSON)]
    }

    static func observedSettings(from root: [String: Any]) -> ObservedSettings? {
        let result = root["result"] as? [String: Any] ?? root
        let model = CodexWireJSON.string(result["model"]) ?? CodexWireJSON.string(result["modelId"])
        let effort = CodexWireJSON.string(result["effort"]) ?? CodexWireJSON.string(result["reasoningEffort"])
        guard model != nil || effort != nil else { return nil }
        return ObservedSettings(
            model: ObservedValue(model, provenance: .harnessReported),
            reasoning: ObservedValue(effort, provenance: .harnessReported)
        )
    }

    private static func metrics(from params: [String: Any]) -> AttemptMetrics {
        let usage = params["usage"] as? [String: Any] ?? params
        let input = CodexWireJSON.int(usage["inputTokens"]) ?? CodexWireJSON.int(usage["input_tokens"])
        let output = CodexWireJSON.int(usage["outputTokens"]) ?? CodexWireJSON.int(usage["output_tokens"])
        return AttemptMetrics(inputTokens: input, outputTokens: output, tokenProvenance: input == nil && output == nil ? .unavailable : .harnessReported)
    }
}

enum CodexWireJSON {
    static func object(_ rawJSON: String) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? { value as? String }
    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    static func requestID(_ value: Any?) -> CodexRequestID? {
        if let number = value as? NSNumber { return .integer(number.intValue) }
        if let string = value as? String { return .string(string) }
        return nil
    }
    static func string(at path: [String], in root: [String: Any]) -> String? {
        var current: Any = root
        for key in path {
            guard let object = current as? [String: Any], let next = object[key] else { return nil }
            current = next
        }
        return current as? String
    }
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { entry in
            if let string = entry as? String { return string }
            guard let object = entry as? [String: Any] else { return nil }
            return string(object["reasoningEffort"]) ?? string(object["id"])
        } ?? []
    }
    static func objects(in value: Any, preferredKeys: [String]) -> [[String: Any]] {
        if let objects = value as? [[String: Any]] { return objects }
        guard let object = value as? [String: Any] else { return [] }
        for key in preferredKeys where object[key] != nil { return objects(in: object[key]!, preferredKeys: []) }
        return []
    }
    static func delta(in params: [String: Any]) -> String? {
        string(params["delta"]) ?? string(params["text"]) ?? string(at: ["item", "text"], in: params)
    }
    static func errorMessage(_ value: Any) -> String? {
        if let object = value as? [String: Any] { return string(object["message"]) ?? string(at: ["error", "message"], in: object) }
        return nil
    }
    static func localEvidence(_ event: String, attemptID: UUID? = nil, text: String? = nil) -> String {
        var object: [String: String] = ["source": "JBench", "event": event]
        if let attemptID { object["attemptID"] = attemptID.uuidString }
        if let text { object["text"] = text }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"source\":\"JBench\"}"
    }
}
