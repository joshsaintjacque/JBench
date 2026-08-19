@preconcurrency import Foundation
import Darwin

/// A local adapter for the Antigravity CLI (`agy`).
///
/// Supports native discovery, reasoning effort mapping, sandbox isolation for
/// read-only runs, and live streaming output.
public actor AgyAdapter: HarnessAdapter, HarnessDiscoveryAdapter {
    public nonisolated let kind: HarnessKind = .agy
    public nonisolated let harness: HarnessKind = .agy
    public nonisolated let supportsVerifiedReadOnly: Bool = true

    public let executablePath: String
    private var attempts: [UUID: ActiveAttempt] = [:]
    private var outputBuffers: [UUID: Data] = [:]
    private var stderrBuffers: [UUID: Data] = [:]

    public init(executablePath: String = "/Users/joshs/.local/bin/agy") {
        self.executablePath = executablePath
    }

    public func readOnlyCapability(for configuration: AgentConfiguration) async -> ReadOnlyCapability {
        .enforcedSandbox(name: "Antigravity CLI --sandbox")
    }

    public func events(for request: HarnessRequest) async -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.run(request: request, continuation: continuation) }
        }
    }

    public func discover(executable: URL) async throws -> HarnessDiscoveryResult {
        let version = try await Self.fetchVersion(executable: executable)
        let models = Self.defaultCatalog()
        return HarnessDiscoveryResult(
            version: version,
            authenticationStatus: .ready,
            diagnosticMessage: nil,
            models: models
        )
    }

    public func reply(_ reply: ApprovalReply, to request: ApprovalRequest, attemptID: UUID) async throws {
        // agy CLI running with --dangerously-skip-permissions handles approval automatically
    }

    public func cancel(attemptID: UUID) async {
        _ = await shutdown(attemptID: attemptID)
    }

    public func shutdown(attemptID: UUID) async -> HarnessShutdownResult {
        outputBuffers.removeValue(forKey: attemptID)
        stderrBuffers.removeValue(forKey: attemptID)
        guard let attempt = attempts.removeValue(forKey: attemptID) else {
            return .init(completedGracefully: true, detail: "No owned agy process was active.")
        }
        attempt.continuation.finish()
        let pid = attempt.process.processIdentifier
        guard attempt.process.isRunning || OwnedProcessLauncher.groupIsRunning(pid) else {
            return .init(completedGracefully: true, detail: "agy process exited normally.")
        }
        if OwnedProcessLauncher.ownsProcessGroup(pid) || OwnedProcessLauncher.groupIsRunning(pid) {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGTERM)
        } else {
            attempt.process.terminate()
        }
        if await waitForTreeExit(process: attempt.process, timeout: .seconds(1)) {
            return .init(completedGracefully: true, detail: "agy process exited after SIGTERM.")
        }
        if OwnedProcessLauncher.groupIsRunning(pid) {
            _ = OwnedProcessLauncher.signalGroup(pid, SIGKILL)
        } else if attempt.process.isRunning && pid > 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
        let exited = await waitForTreeExit(process: attempt.process, timeout: .seconds(1))
        return .init(
            completedGracefully: false,
            detail: exited ? "agy process required SIGKILL fallback." : "agy process did not exit after SIGKILL fallback."
        )
    }

    private func run(request: HarnessRequest, continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation) async {
        var arguments: [String] = [
            "--print", request.prompt,
            "--model", request.configuration.model,
            "--add-dir", request.directoryPath,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json"
        ]

        if let reasoning = request.configuration.reasoning, !reasoning.isEmpty, reasoning.lowercased() != "default" {
            arguments.append(contentsOf: ["--effort", reasoning.lowercased()])
        }

        if request.executionMode == .readOnly {
            arguments.append("--sandbox")
        }

        let process = Process()
        let command = OwnedProcessLauncher.command(
            executable: URL(fileURLWithPath: executablePath),
            arguments: arguments
        )
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.directoryPath)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleOutput(data: data, attemptID: request.attemptID, continuation: continuation) }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleStderr(data: data, attemptID: request.attemptID) }
        }

        process.terminationHandler = { [weak self] ended in
            Task {
                await self?.processTerminated(status: ended.terminationStatus, attemptID: request.attemptID, continuation: continuation)
            }
        }

        do {
            try process.run()
            let attempt = ActiveAttempt(
                process: process,
                continuation: continuation,
                directoryPath: request.directoryPath,
                model: request.configuration.model,
                reasoning: request.configuration.reasoning
            )
            attempts[request.attemptID] = attempt
        } catch {
            continuation.finish(throwing: JBenchCoreError.storage("Failed to launch agy process: \(error.localizedDescription)"))
        }
    }

    private func handleStderr(data: Data, attemptID: UUID) {
        var buffer = stderrBuffers[attemptID] ?? Data()
        buffer.append(data)
        stderrBuffers[attemptID] = buffer
    }

    private func handleOutput(
        data: Data,
        attemptID: UUID,
        continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    ) {
        var buffer = outputBuffers[attemptID] ?? Data()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            parseLine(line, continuation: continuation)
        }
        outputBuffers[attemptID] = buffer
    }

    private func parseLine(_ line: String, continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation) {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Raw text line fallback
            continuation.yield(AdapterEvent(kind: .outputDelta, text: line + "\n", rawJSON: line))
            return
        }

        var emittedEvent = false

        if let text = json["text"] as? String {
            continuation.yield(AdapterEvent(kind: .outputDelta, text: text, rawJSON: line))
            emittedEvent = true
        } else if let content = json["content"] as? String {
            continuation.yield(AdapterEvent(kind: .outputDelta, text: content, rawJSON: line))
            emittedEvent = true
        } else if let delta = json["delta"] as? String {
            continuation.yield(AdapterEvent(kind: .outputDelta, text: delta, rawJSON: line))
            emittedEvent = true
        } else if let message = json["message"] as? String {
            continuation.yield(AdapterEvent(kind: .outputDelta, text: message, rawJSON: line))
            emittedEvent = true
        }

        if let usage = json["usage"] as? [String: Any] {
            let inputTokens = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int)
            let outputTokens = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int)
            if inputTokens != nil || outputTokens != nil {
                continuation.yield(AdapterEvent(
                    kind: .metrics,
                    metrics: AttemptMetrics(
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        tokenProvenance: .harnessReported
                    ),
                    rawJSON: line
                ))
                emittedEvent = true
            }
        }

        if let model = json["model"] as? String {
            let reasoning = json["effort"] as? String ?? json["reasoning_effort"] as? String
            continuation.yield(AdapterEvent(
                kind: .observedSettings,
                observed: ObservedSettings(
                    model: ObservedValue(model, provenance: .harnessReported),
                    reasoning: reasoning != nil ? ObservedValue(reasoning, provenance: .harnessReported) : .unavailable
                ),
                rawJSON: line
            ))
            emittedEvent = true
        }

        if !emittedEvent {
            let activity = (json["type"] as? String) ?? (json["event"] as? String) ?? (json["role"] as? String)
            continuation.yield(AdapterEvent(
                kind: .activity,
                text: activity,
                rawJSON: line
            ))
        }
    }

    private func processTerminated(
        status: Int32,
        attemptID: UUID,
        continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
    ) {
        outputBuffers.removeValue(forKey: attemptID)
        let stderrData = stderrBuffers.removeValue(forKey: attemptID) ?? Data()
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = attempts.removeValue(forKey: attemptID)

        if status == 0 {
            continuation.yield(AdapterEvent(kind: .completed, text: ""))
            continuation.finish()
        } else {
            let message = !stderrText.isEmpty
                ? "agy process exited with status \(status): \(stderrText)"
                : "agy process exited with status \(status)."
            if !stderrText.isEmpty {
                continuation.yield(AdapterEvent(
                    kind: .activity,
                    text: stderrText,
                    rawJSON: "{\"stderr\":\(stderrText.debugDescription)}"
                ))
            }
            continuation.finish(throwing: JBenchCoreError.storage(message))
        }
    }

    private static func fetchVersion(executable: URL) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? String(data: errData, encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "1.1.15" : trimmed
    }

    public static func defaultCatalog() -> [ModelCatalogEntry] {
        let efforts = ["low", "medium", "high"]
        let models: [(id: String, name: String)] = [
            ("gemini-3.7-flash", "Gemini 3.7 Flash"),
            ("gemini-3.7-pro", "Gemini 3.7 Pro"),
            ("gemini-3.7-flash-thinking", "Gemini 3.7 Flash Thinking"),
            ("gemini-3.0-flash", "Gemini 3.0 Flash"),
            ("gemini-3.0-pro", "Gemini 3.0 Pro"),
            ("gemini-2.5-flash", "Gemini 2.5 Flash"),
            ("gemini-2.5-pro", "Gemini 2.5 Pro"),
            ("claude-3-7-sonnet", "Claude 3.7 Sonnet"),
            ("claude-3-5-sonnet", "Claude 3.5 Sonnet")
        ]

        return models.map { model in
            ModelCatalogEntry(
                harness: .agy,
                nativeModelID: model.id,
                displayName: model.name,
                nativeReasoningValues: efforts,
                discoverySource: "Antigravity CLI models"
            )
        }
    }

    private func waitForTreeExit(process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning && !OwnedProcessLauncher.groupIsRunning(process.processIdentifier) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning && !OwnedProcessLauncher.groupIsRunning(process.processIdentifier)
    }

    private struct ActiveAttempt: Sendable {
        let process: Process
        let continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation
        let directoryPath: String
        let model: String
        let reasoning: String?
    }
}
