@preconcurrency import Foundation
import Darwin

/// A local OpenCode server adapter. Each attempt owns one loopback server so that
/// cancellation and evidence boundaries remain lane-specific.
public actor OpenCodeAdapter: HarnessAdapter, HarnessDiscoveryAdapter {
    public nonisolated let kind: HarnessKind = .openCode
    public nonisolated let harness: HarnessKind = .openCode
    /// OpenCode permission rules are a configured gate, not a hard filesystem
    /// sandbox. Set this only when the composition layer also supplies a sentinel
    /// verifier that attests the attempt did not mutate its target directory.
    public nonisolated let supportsVerifiedReadOnly: Bool

    public let executablePath: String
    /// Supplied by composition only after a version-specific write-block sentinel
    /// has succeeded. A UI label alone must never create this contract.
    public let verifiedReadOnlyContract: ReadOnlyVerification?
    private var attempts: [UUID: ActiveAttempt] = [:]

    public init(executablePath: String = "/Users/joshs/.opencode/bin/opencode", verifiedReadOnlyContract: ReadOnlyVerification? = nil) {
        self.executablePath = executablePath
        self.verifiedReadOnlyContract = verifiedReadOnlyContract
        // OpenCode's permission handling is never equivalent to a filesystem sandbox.
        self.supportsVerifiedReadOnly = false
    }

    /// Compatibility overload. The legacy Boolean is intentionally ignored: it
    /// cannot make OpenCode a sandboxed harness. Pass `verifiedReadOnlyContract`
    /// only after the version-specific sentinel has succeeded.
    public init(executablePath: String, supportsVerifiedReadOnly: Bool) {
        self.init(executablePath: executablePath, verifiedReadOnlyContract: nil)
    }

    public func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability {
        guard let contract = verifiedReadOnlyContract, contract.succeeded else {
            return .unavailable(reason: "OpenCode needs a version-specific successful write-block sentinel before a read-only lane can start.")
        }
        return .configuredRestrictionsRequireSentinel(name: contract.detail)
    }

    public func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.run(request: request, continuation: continuation) }
        }
    }

    /// Starts a short-lived local server and queries only documented discovery
    /// paths. It does not create a session or send a provider prompt.
    public func discover(executable: URL) async throws -> HarnessDiscoveryResult {
        let launched = try Self.launch(executablePath: executable.path)
        do {
            let baseURL = try await Self.serverURL(from: launched.output)
            guard await Self.isReady(baseURL: baseURL, directoryPath: FileManager.default.currentDirectoryPath) else {
                throw OpenCodeAdapterError.protocolFailure("The OpenCode server did not become ready for discovery.")
            }
            let directoryPath = FileManager.default.currentDirectoryPath
            async let versionResponse = Self.optionalRequest(baseURL: baseURL, path: "/version", directoryPath: directoryPath)
            async let providerResponse = Self.optionalRequest(baseURL: baseURL, path: "/provider", directoryPath: directoryPath)
            async let configuredProviderResponse = Self.optionalRequest(baseURL: baseURL, path: "/config/providers", directoryPath: directoryPath)
            async let authResponse = Self.optionalRequest(baseURL: baseURL, path: "/provider/auth", directoryPath: directoryPath)
            let (version, providers, configuredProviders, auth) = await (versionResponse, providerResponse, configuredProviderResponse, authResponse)

            let providerModels = providers.map { OpenCodeWireParser.catalogEntries(from: $0.body, source: "OpenCode GET /provider") } ?? []
            let configuredModels = configuredProviders.map { OpenCodeWireParser.catalogEntries(from: $0.body, source: "OpenCode GET /config/providers") } ?? []
            let models = Self.deduplicatedCatalog(providerModels + configuredModels)
            let reportedVersion = version.flatMap { OpenCodeWireParser.version(from: $0.body) }
            let authentication = auth.map { OpenCodeWireParser.authenticationStatus(from: $0.body, statusCode: $0.statusCode) } ?? .unknown
            let result = HarnessDiscoveryResult(
                version: reportedVersion,
                authenticationStatus: authentication,
                diagnosticMessage: models.isEmpty ? "OpenCode returned no native models." : nil,
                models: models
            )
            _ = await Self.terminateOwnedProcess(launched.process)
            return result
        } catch {
            _ = await Self.terminateOwnedProcess(launched.process)
            throw error
        }
    }

    public func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {
        guard let attempt = attempts[attemptID], let baseURL = attempt.baseURL, let sessionID = attempt.sessionID,
              let permissionID = attempt.permissionIDs[request.id] else {
            throw JBenchCoreError.unsupportedApproval
        }
        try await Self.sendPermissionReply(
            baseURL: baseURL,
            directoryPath: attempt.directoryPath,
            sessionID: sessionID,
            permissionID: permissionID,
            reply: reply
        )
        var updated = attempt
        updated.permissionIDs[request.id] = nil
        attempts[attemptID] = updated
    }

    public func cancel(attemptID: UUID) async {
        _ = await shutdown(attemptID: attemptID)
    }

    public func shutdown(attemptID: UUID) async -> HarnessShutdownResult {
        guard let attempt = attempts.removeValue(forKey: attemptID) else {
            return .init(completedGracefully: true, detail: "No owned OpenCode process was active.")
        }
        var abortDetail: String?
        if let baseURL = attempt.baseURL, let sessionID = attempt.sessionID {
            do {
                try await Self.abort(baseURL: baseURL, directoryPath: attempt.directoryPath, sessionID: sessionID)
            } catch {
                abortDetail = "OpenCode abort request failed: \(error.localizedDescription)"
            }
        }
        attempt.continuation.finish()
        let termination = await Self.terminateOwnedProcess(attempt.process)
        let detail = [abortDetail, termination.detail].compactMap { $0 }.joined(separator: " ")
        return .init(completedGracefully: termination.stoppedGracefully && abortDetail == nil, detail: detail.isEmpty ? nil : detail)
    }

    /// Gets native provider/model IDs from the local server. The result remains
    /// native rather than normalising provider names or reasoning levels.
    public static func discoverModels(baseURL: URL, directoryPath: String) async throws -> [ModelCatalogEntry] {
        let response = try await request(method: "GET", baseURL: baseURL, path: "/provider", directoryPath: directoryPath)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeAdapterError.http(statusCode: response.statusCode, body: response.body)
        }
        return OpenCodeWireParser.catalogEntries(from: response.body)
    }

    /// Checks the server paths used by this adapter. It does not start a prompt.
    public static func isReady(baseURL: URL, directoryPath: String) async -> Bool {
        guard let response = try? await request(method: "GET", baseURL: baseURL, path: "/path", directoryPath: directoryPath) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    private func run(request: HarnessRequest, continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation) async {
        var process: Process?
        do {
            let launched = try Self.launch(executablePath: executablePath)
            process = launched.process
            attempts[request.attemptID] = ActiveAttempt(
                process: launched.process,
                baseURL: nil,
                sessionID: nil,
                directoryPath: request.directoryPath,
                executionMode: request.executionMode,
                approvalPolicy: request.configuration.approvalPolicy,
                continuation: continuation
            )
            let baseURL = try await Self.serverURL(from: launched.output)
            guard var active = attempts[request.attemptID] else { return }
            active.baseURL = baseURL
            attempts[request.attemptID] = active

            guard await Self.isReady(baseURL: baseURL, directoryPath: request.directoryPath) else {
                throw OpenCodeAdapterError.protocolFailure("The OpenCode server did not become ready.")
            }
            let session = try await Self.createSession(baseURL: baseURL, directoryPath: request.directoryPath)
            guard var sessionActive = attempts[request.attemptID] else { return }
            sessionActive.sessionID = session.id
            attempts[request.attemptID] = sessionActive
            let lifecycle = AttemptLifecycleMetadata(
                ownership: .init(
                    serverProcessID: launched.process.processIdentifier,
                    serverIdentity: OwnedProcessService.identity(for: launched.process.processIdentifier)?.serialized ?? ""
                ),
                protocolSessionID: session.id
            )
            continuation.yield(.init(kind: .lifecycle, lifecycle: lifecycle, rawJSON: session.rawJSON))
            if request.executionMode == .readOnly {
                guard let contract = verifiedReadOnlyContract, contract.succeeded else {
                    throw OpenCodeAdapterError.protocolFailure("OpenCode read-only execution was requested without a verified sentinel contract.")
                }
                continuation.yield(.init(kind: .readOnlyVerification, readOnlyVerification: contract, rawJSON: "{\"readOnlySentinel\":\"composition-verified\",\"detail\":\"\(Self.jsonEscaped(contract.detail))\"}"))
                continuation.yield(.init(
                    kind: .activity,
                    text: "OpenCode read-only permission gate configured; sentinel verification is still required.",
                    rawJSON: "{\"readOnlyPermissionGate\":\"configured-not-verified\"}"
                ))
            }
            continuation.yield(.init(kind: .started, rawJSON: session.rawJSON))

            try await consumeSessionEvents(baseURL: baseURL, sessionID: session.id, request: request, continuation: continuation)
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.yield(.init(kind: .failed, text: error.localizedDescription, rawJSON: Self.errorJSON(error)))
            continuation.finish(throwing: error)
        }
        if let active = attempts.removeValue(forKey: request.attemptID) {
            _ = await Self.terminateOwnedProcess(active.process)
        } else if let process {
            _ = await Self.terminateOwnedProcess(process)
        }
    }

    private func consumeSessionEvents(
        baseURL: URL,
        sessionID: String,
        request: HarnessRequest,
        continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    ) async throws {
        var sseRequest = URLRequest(url: try Self.url(baseURL: baseURL, path: "/event", directoryPath: request.directoryPath))
        sseRequest.httpMethod = "GET"
        sseRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: sseRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenCodeAdapterError.protocolFailure("OpenCode refused its event stream.")
        }

        // The SSE connection is open before this request. That avoids losing the
        // first output event from a fast local provider.
        try await Self.prompt(
            baseURL: baseURL,
            directoryPath: request.directoryPath,
            sessionID: sessionID,
            model: request.configuration.model,
            prompt: request.prompt,
            reasoning: request.configuration.reasoning
        )

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, raw != "[DONE]" else { continue }
            let parsed = OpenCodeWireParser.parseEvent(raw)
            await handle(parsed: parsed, rawJSON: raw, request: request, continuation: continuation)
            if parsed.isTerminal { return }
        }
    }

    private func handle(
        parsed: OpenCodeParsedEvent,
        rawJSON: String,
        request: HarnessRequest,
        continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    ) async {
        switch parsed.kind {
        case .textDelta:
            continuation.yield(.init(kind: .outputDelta, text: parsed.text, rawJSON: rawJSON))
        case .activity:
            continuation.yield(.init(kind: .activity, text: parsed.text, rawJSON: rawJSON))
        case .observed:
            continuation.yield(.init(kind: .observedSettings, observed: parsed.observed, rawJSON: rawJSON))
            if let metrics = parsed.metrics { continuation.yield(.init(kind: .metrics, metrics: metrics, rawJSON: rawJSON)) }
        case .metrics:
            continuation.yield(.init(kind: .metrics, metrics: parsed.metrics, rawJSON: rawJSON))
        case .permission:
            guard let nativeID = parsed.permissionID else {
                continuation.yield(.init(kind: .activity, text: "OpenCode requested an unidentifiable permission.", rawJSON: rawJSON))
                return
            }
            guard let active = attempts[request.attemptID], let baseURL = active.baseURL, let sessionID = active.sessionID else { return }
            if Self.mustAutomaticallyDeny(permissionCategory: parsed.permissionCategory, active: active) {
                try? await Self.sendPermissionReply(baseURL: baseURL, directoryPath: active.directoryPath, sessionID: sessionID, permissionID: nativeID, reply: .decline)
                continuation.yield(.init(kind: .activity, text: "Denied \(parsed.permissionCategory ?? "restricted") permission.", rawJSON: rawJSON))
            } else if active.approvalPolicy == .allowForAttempt {
                try? await Self.sendPermissionReply(baseURL: baseURL, directoryPath: active.directoryPath, sessionID: sessionID, permissionID: nativeID, reply: .approveForAttempt)
                continuation.yield(.init(kind: .activity, text: "Approved for this attempt.", rawJSON: rawJSON))
            } else if active.approvalPolicy == .denyAll {
                try? await Self.sendPermissionReply(baseURL: baseURL, directoryPath: active.directoryPath, sessionID: sessionID, permissionID: nativeID, reply: .decline)
                continuation.yield(.init(kind: .activity, text: "Denied by lane policy.", rawJSON: rawJSON))
            } else {
                let approval = ApprovalRequest(summary: parsed.permissionSummary ?? "OpenCode requested permission.", targetPath: parsed.targetPath, permissionCategory: parsed.permissionCategory)
                var updated = active
                updated.permissionIDs[approval.id] = nativeID
                attempts[request.attemptID] = updated
                continuation.yield(.init(kind: .approvalRequest, approval: approval, rawJSON: rawJSON))
            }
        case .completed:
            continuation.yield(.init(kind: .completed, rawJSON: rawJSON))
        case .failed:
            continuation.yield(.init(kind: .failed, text: parsed.text ?? "OpenCode reported a session error.", rawJSON: rawJSON))
        }
    }

    private static func mustAutomaticallyDeny(permissionCategory: String?, active: ActiveAttempt) -> Bool {
        if active.approvalPolicy == .denyAll { return true }
        guard active.executionMode == .readOnly else { return false }
        let category = (permissionCategory ?? "").lowercased()
        return ["edit", "write", "bash", "shell", "task", "webfetch", "websearch", "delete", "patch"].contains { category.contains($0) }
    }

    private static func launch(executablePath: String) throws -> (process: Process, output: FileHandle) {
        let process = Process()
        let output = Pipe()
        let command = OwnedProcessLauncher.command(
            executable: URL(fileURLWithPath: executablePath),
            arguments: ["serve", "--hostname", "127.0.0.1", "--port", "0", "--pure"]
        )
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output.fileHandleForReading)
    }

    private static func serverURL(from output: FileHandle) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for try await line in output.bytes.lines {
                    if let url = OpenCodeWireParser.serverURL(from: line) { return url }
                }
                throw OpenCodeAdapterError.protocolFailure("OpenCode exited before it printed its server URL.")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw OpenCodeAdapterError.protocolFailure("Timed out waiting for OpenCode to start.")
            }
            guard let first = try await group.next() else {
                throw OpenCodeAdapterError.protocolFailure("OpenCode did not start.")
            }
            group.cancelAll()
            return first
        }
    }

    private static func createSession(baseURL: URL, directoryPath: String) async throws -> (id: String, rawJSON: String) {
        let response = try await request(method: "POST", baseURL: baseURL, path: "/session", directoryPath: directoryPath, jsonBody: [:])
        guard (200..<300).contains(response.statusCode), let id = OpenCodeWireParser.string(in: response.body, paths: [["id"], ["session", "id"]]) else {
            throw OpenCodeAdapterError.http(statusCode: response.statusCode, body: response.body)
        }
        return (id, response.body)
    }

    private static func prompt(baseURL: URL, directoryPath: String, sessionID: String, model: String, prompt: String, reasoning: String?) async throws {
        let body = promptBody(model: model, prompt: prompt, reasoning: reasoning)
        let response = try await request(method: "POST", baseURL: baseURL, path: "/session/\(sessionID)/prompt_async", directoryPath: directoryPath, jsonBody: body)
        guard (200..<300).contains(response.statusCode) else { throw OpenCodeAdapterError.http(statusCode: response.statusCode, body: response.body) }
    }

    static func promptBody(model: String, prompt: String, reasoning: String?) -> [String: Any] {
        let modelParts = model.split(separator: "/", maxSplits: 1).map(String.init)
        let providerID = modelParts.count == 2 ? modelParts[0] : ""
        let modelID = modelParts.count == 2 ? modelParts[1] : model
        var body: [String: Any] = [
            "model": ["providerID": providerID, "modelID": modelID],
            "parts": [["type": "text", "text": prompt]]
        ]
        if let reasoning { body["variant"] = reasoning }
        return body
    }

    private static func abort(baseURL: URL, directoryPath: String, sessionID: String) async throws {
        _ = try await request(method: "POST", baseURL: baseURL, path: "/session/\(sessionID)/abort", directoryPath: directoryPath, jsonBody: [:])
    }

    private static func sendPermissionReply(baseURL: URL, directoryPath: String, sessionID: String, permissionID: String, reply: ApprovalReply) async throws {
        let response: String
        switch reply {
        case .approveOnce: response = "once"
        case .approveForAttempt: response = "always"
        case .decline: response = "reject"
        }
        let result = try await request(method: "POST", baseURL: baseURL, path: "/session/\(sessionID)/permissions/\(permissionID)", directoryPath: directoryPath, jsonBody: ["response": response])
        guard (200..<300).contains(result.statusCode) else { throw OpenCodeAdapterError.http(statusCode: result.statusCode, body: result.body) }
    }

    private static func request(method: String, baseURL: URL, path: String, directoryPath: String, jsonBody: [String: Any]? = nil) async throws -> HTTPResult {
        var request = URLRequest(url: try url(baseURL: baseURL, path: path, directoryPath: directoryPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeAdapterError.protocolFailure("OpenCode returned a non-HTTP response.") }
        return HTTPResult(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    private static func optionalRequest(baseURL: URL, path: String, directoryPath: String) async -> HTTPResult? {
        guard let response = try? await request(method: "GET", baseURL: baseURL, path: path, directoryPath: directoryPath),
              (200..<300).contains(response.statusCode) else { return nil }
        return response
    }

    private static func deduplicatedCatalog(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.nativeModelID).inserted }
    }

    private static func url(baseURL: URL, path: String, directoryPath: String) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw OpenCodeAdapterError.protocolFailure("Could not construct an OpenCode server URL.")
        }
        components.queryItems = [URLQueryItem(name: "directory", value: directoryPath)]
        guard let result = components.url else { throw OpenCodeAdapterError.protocolFailure("Could not encode the OpenCode directory.") }
        return result
    }

    static func terminateOwnedProcess(_ process: Process) async -> OpenCodeTerminationResult {
        let pid = process.processIdentifier
        let ownsGroup = OwnedProcessLauncher.ownsProcessGroup(pid) || OwnedProcessLauncher.groupIsRunning(pid)
        guard process.isRunning || (ownsGroup && OwnedProcessLauncher.groupIsRunning(pid)) else { return .init(stoppedGracefully: true, detail: "Owned OpenCode server was already stopped.") }
        if ownsGroup { _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM) } else { process.terminate() }
        let gracefulDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (process.isRunning || (ownsGroup && OwnedProcessLauncher.groupIsRunning(pid))), ContinuousClock.now < gracefulDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !process.isRunning && (!ownsGroup || !OwnedProcessLauncher.groupIsRunning(pid)) { return .init(stoppedGracefully: true, detail: "Owned OpenCode process tree exited after SIGTERM.") }

        // `Process.isRunning` is tied to this launched child, so no unrelated
        // process is targeted even if an OS PID has been recycled elsewhere.
        guard pid > 0 else { return .init(stoppedGracefully: false, detail: "Owned OpenCode server did not expose a PID for SIGKILL fallback.") }
        let signaled = ownsGroup ? OwnedProcessLauncher.signalGroup(pid, SIGKILL) : Darwin.kill(pid, SIGKILL) == 0
        guard signaled else {
            return .init(stoppedGracefully: false, detail: "SIGKILL fallback failed for owned OpenCode server PID \(pid): \(String(cString: strerror(errno))).")
        }
        let fallbackDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while (process.isRunning || (ownsGroup && OwnedProcessLauncher.groupIsRunning(pid))), ContinuousClock.now < fallbackDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process.isRunning || (ownsGroup && OwnedProcessLauncher.groupIsRunning(pid))
            ? .init(stoppedGracefully: false, detail: "Owned OpenCode server PID \(pid) remained running after SIGKILL fallback.")
            : .init(stoppedGracefully: false, detail: "Owned OpenCode server exited after SIGKILL fallback.")
    }

    private static func errorJSON(_ error: Error) -> String {
        let message = jsonEscaped(error.localizedDescription)
        return "{\"adapterError\":\"\(message)\"}"
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public enum OpenCodeAdapterError: LocalizedError, Sendable, Equatable {
    case http(statusCode: Int, body: String)
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .http(statusCode, body): "OpenCode server returned HTTP \(statusCode): \(body)"
        case let .protocolFailure(message): message
        }
    }
}

private struct ActiveAttempt {
    var process: Process
    var baseURL: URL?
    var sessionID: String?
    var directoryPath: String
    var executionMode: ExecutionMode
    var approvalPolicy: ApprovalPolicy
    var continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    var permissionIDs: [UUID: String] = [:]
}

private struct HTTPResult: Sendable {
    var statusCode: Int
    var body: String
}

struct OpenCodeTerminationResult: Sendable {
    var stoppedGracefully: Bool
    var detail: String
}
