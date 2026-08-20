import Foundation
import Testing
@testable import JBenchCore

struct CodexAdapterTests {
    @Test func turnRequestPreservesNativePromptDirectoryModelAndEffort() throws {
        let request = HarnessRequest(
            runID: UUID(),
            attemptID: UUID(),
            prompt: "Return the exact heading only.",
            directoryPath: "/Users/josh/work/project",
            executionMode: .readOnly,
            configuration: AgentConfiguration(harness: .codex, model: "gpt-5.6-sol", reasoning: "high")
        )

        let params = CodexWireRequest.turnStartParams(for: request, threadID: "thread-1")
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["model"] as? String == "gpt-5.6-sol")
        #expect(params["effort"] as? String == "high")
        #expect(params["cwd"] as? String == "/Users/josh/work/project")
        #expect(params["sandboxPolicy"] as? [String: String] == ["type": "read-only"])
        let input = try #require(params["input"] as? [[String: String]])
        #expect(input == [["type": "text", "text": "Return the exact heading only."]])

        let threadParams = CodexWireRequest.threadStartParams(for: request)
        #expect(threadParams["sandbox"] as? String == "read-only")
        #expect(CodexWireRequest.approvalPolicy(for: .askEveryTime) == "on-request")
        #expect(CodexWireRequest.approvalPolicy(for: .allowForAttempt) == "on-request")
        #expect(CodexWireRequest.approvalPolicy(for: .denyAll) == "never")
        #expect(CodexWireRequest.automaticApprovalDecision(for: .askEveryTime) == nil)
        #expect(CodexWireRequest.automaticApprovalDecision(for: .allowForAttempt) == "acceptForSession")
        #expect(CodexWireRequest.automaticApprovalDecision(for: .denyAll) == nil)
    }

    @Test func editableRequestsUseCurrentCodexSandboxEnum() throws {
        let request = HarnessRequest(
            runID: UUID(),
            attemptID: UUID(),
            prompt: "Inspect the project.",
            directoryPath: "/Users/josh/work/project",
            executionMode: .editable,
            configuration: AgentConfiguration(harness: .codex, model: "gpt-5.6-luna")
        )

        #expect(CodexWireRequest.threadStartParams(for: request)["sandbox"] as? String == "workspace-write")
        #expect(CodexWireRequest.turnStartParams(for: request, threadID: "thread-1")["sandboxPolicy"] as? [String: String] == ["type": "workspace-write"])
    }

    @Test func fixtureNotificationsStreamRawOutputSettingsAndUsage() throws {
        let message = #"{"method":"item/agentMessage/delta","params":{"delta":"Hello"}}"#
        let messageRoot = try #require(CodexWireJSON.object(message))
        let output = CodexWireDecoder.events(method: "item/agentMessage/delta", root: messageRoot, rawJSON: message)
        #expect(output.count == 1)
        #expect(output[0].kind == .outputDelta)
        #expect(output[0].text == "Hello")
        #expect(output[0].rawJSON == message)

        let usage = #"{"method":"turn/usageUpdated","params":{"usage":{"inputTokens":21,"outputTokens":34}}}"#
        let usageRoot = try #require(CodexWireJSON.object(usage))
        let metrics = CodexWireDecoder.events(method: "turn/usageUpdated", root: usageRoot, rawJSON: usage)
        #expect(metrics[0].metrics?.inputTokens == 21)
        #expect(metrics[0].metrics?.outputTokens == 34)
        #expect(metrics[0].metrics?.tokenProvenance == .harnessReported)

        let reroute = #"{"method":"model/rerouted","params":{"model":"gpt-5.6-sol","effort":"high"}}"#
        let rerouteRoot = try #require(CodexWireJSON.object(reroute))
        let observed = CodexWireDecoder.events(method: "model/rerouted", root: rerouteRoot, rawJSON: reroute)
        #expect(observed[0].observed?.model.value == "gpt-5.6-sol")
        #expect(observed[0].observed?.reasoning.value == "high")
    }

    @Test func catalogFixturePreservesServerOrderAndNativeEfforts() {
        let fixture = #"{"id":3,"result":{"models":[{"id":"gpt-5.6-sol","displayName":"Sol","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high","description":"Deep"},{"reasoningEffort":"max","description":"Maximum"}]},{"model":"gpt-5.6-luna","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]}]}}"#
        let catalog = CodexAppServerAdapter.catalog(fromModelListJSON: fixture, catalogedAt: Date(timeIntervalSince1970: 0))
        #expect(catalog.map(\.nativeModelID) == ["gpt-5.6-sol", "gpt-5.6-luna"])
        #expect(catalog[0].nativeReasoningValues == ["low", "high", "max"])
        #expect(catalog[1].displayName == nil)
        #expect(catalog.allSatisfy { $0.catalogedAt == Date(timeIntervalSince1970: 0) })
    }

    @Test func allowForAttemptRepliesToNativeApprovalWithoutSurfacingIt() async throws {
        let fixture = try CodexTestFixture(script: """
        read line
        printf '%s\\n' '{"id":1,"result":{}}'
        read line
        read line
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        read line
        printf '%s\\n' '{"id":3,"method":"item/commandExecution/requestApproval","params":{"command":"touch fixture"}}'
        read line
        printf '%s\\n' "$line" > '__JBenchCodexResponseFile__'
        printf '%s\\n' '{"method":"turn/completed","params":{}}'
        """)
        defer { fixture.remove() }

        let adapter = CodexAppServerAdapter(executableURL: fixture.executable)
        let request = HarnessRequest(
            runID: UUID(),
            attemptID: UUID(),
            prompt: "fixture",
            directoryPath: FileManager.default.temporaryDirectory.path,
            executionMode: .readOnly,
            configuration: AgentConfiguration(harness: .codex, model: "fixture", approvalPolicy: .allowForAttempt)
        )

        var events: [AdapterEvent] = []
        for try await event in await adapter.events(for: request) { events.append(event) }

        #expect(!events.contains { $0.kind == .approvalRequest })
        #expect(events.contains { $0.kind == .activity && $0.text == "Approved for this attempt." })
        let response = try String(contentsOf: fixture.responseFile, encoding: .utf8)
        let responseObject = try #require(CodexWireJSON.object(response))
        #expect(responseObject["id"] as? Int == 3)
        #expect(CodexWireJSON.string(at: ["result", "decision"], in: responseObject) == "acceptForSession")
    }

    @Test func finalCompletedNotificationWinsWhenStdoutHandlingIsDelayedPastProcessExit() async throws {
        let fixture = try CodexTestFixture(script: """
        read line
        printf '%s\\n' '{"id":1,"result":{}}'
        read line
        read line
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        read line
        printf '%s\\n' '{"method":"turn/completed","params":{"message":"done"}}'
        """)
        defer { fixture.remove() }

        let adapter = CodexAppServerAdapter(
            executableURL: fixture.executable,
            clientName: "JBenchTests",
            clientVersion: "1",
            stdoutProcessingDelay: .milliseconds(150)
        )
        let request = HarnessRequest(
            runID: UUID(),
            attemptID: UUID(),
            prompt: "fixture",
            directoryPath: FileManager.default.temporaryDirectory.path,
            executionMode: .readOnly,
            configuration: AgentConfiguration(harness: .codex, model: "fixture")
        )

        var events: [AdapterEvent] = []
        for try await event in await adapter.events(for: request) { events.append(event) }

        #expect(events.contains { $0.kind == .completed && $0.text == "done" })
        #expect(!events.contains { $0.kind == .failed })
    }

    @Test func discoveryTimeoutTerminatesItsHungFakeAppServer() async throws {
        let fixture = try CodexTestFixture(script: """
        while true; do sleep 1; done
        """)
        defer { fixture.remove() }

        let probe = CodexDiscoveryProbe(
            executableURL: fixture.executable,
            clientName: "JBenchTests",
            clientVersion: "1",
            timeout: .milliseconds(300),
            shutdownGrace: .milliseconds(100)
        )
        var diagnostic = ""
        do {
            _ = try await probe.run()
            Issue.record("Expected discovery timeout")
        } catch {
            diagnostic = error.localizedDescription
        }
        #expect(diagnostic.contains("discovery timed out"))
        #expect(diagnostic.contains("Terminated the owned Codex discovery process group.")
            || diagnostic.contains("Forced termination of the owned Codex discovery process completed."))
    }

    @Test func discoveryCleanupTerminatesSurvivingOwnedGroupAfterLeaderExits() async throws {
        let fixture = try CodexTestFixture(script: """
        read line
        (
            trap '' TERM
            while true; do sleep 1; done
        ) &
        child_pid=$!
        printf '%s\\n' "$$" > '__JBenchCodexGroupPIDFile__'
        printf '%s\\n' "$child_pid" > '__JBenchCodexChildPIDFile__'
        exit 0
        """)
        defer {
            fixture.stopRecordedGroup()
            fixture.remove()
        }

        let probe = CodexDiscoveryProbe(
            executableURL: fixture.executable,
            clientName: "JBenchTests",
            clientVersion: "1",
            shutdownGrace: .milliseconds(100)
        )
        do {
            _ = try await probe.run()
            Issue.record("Expected discovery process exit")
        } catch {
            #expect(error.localizedDescription.contains("discovery exited with status 0"))
        }

        let groupPID = try #require(fixture.recordedGroupPID())
        #expect(fixture.recordedChildPID() != nil)
        let stopped = await fixture.waitForGroupExit(groupPID, timeout: .seconds(2))
        #expect(stopped)
    }

    @Test func discoveryRefusesToSignalWhenIdentityCannotBeCaptured() async throws {
        let fixture = try CodexTestFixture(script: """
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }

        let probe = CodexDiscoveryProbe(
            executableURL: fixture.executable,
            clientName: "JBenchTests",
            clientVersion: "1",
            processIdentityProvider: { _ in nil }
        )
        do {
            _ = try await probe.run()
            Issue.record("Expected ownership failure")
        } catch {
            #expect(error.localizedDescription.contains("Could not establish ownership"))
            #expect(error.localizedDescription.contains("no signal was sent"))
        }
    }
}

private struct CodexTestFixture {
    let directory: URL
    let executable: URL
    let responseFile: URL
    let groupPIDFile: URL
    let childPIDFile: URL

    init(script: String) throws {
        let buildDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".build", isDirectory: true)
        directory = buildDirectory.appendingPathComponent("JBenchCodexAdapterTests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("codex")
        responseFile = directory.appendingPathComponent("response.json")
        groupPIDFile = directory.appendingPathComponent("group.pid")
        childPIDFile = directory.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedScript = script
            .replacingOccurrences(of: "__JBenchCodexResponseFile__", with: Self.shellQuoted(responseFile.path))
            .replacingOccurrences(of: "__JBenchCodexGroupPIDFile__", with: Self.shellQuoted(groupPIDFile.path))
            .replacingOccurrences(of: "__JBenchCodexChildPIDFile__", with: Self.shellQuoted(childPIDFile.path))
        try ("#!/bin/sh\nset -eu\n" + resolvedScript).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func recordedGroupPID() -> Int32? {
        recordedPID(in: groupPIDFile)
    }

    func recordedChildPID() -> Int32? {
        recordedPID(in: childPIDFile)
    }

    func stopRecordedGroup() {
        guard let groupPID = recordedGroupPID(), OwnedProcessLauncher.groupIsRunning(groupPID) else { return }
        _ = OwnedProcessLauncher.signalGroup(groupPID, SIGKILL)
    }

    func waitForGroupExit(_ groupPID: Int32, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while OwnedProcessLauncher.groupIsRunning(groupPID), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !OwnedProcessLauncher.groupIsRunning(groupPID)
    }

    private static func shellQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\\\''")
    }

    private func recordedPID(in file: URL) -> Int32? {
        guard let value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(value), pid > 0 else { return nil }
        return pid
    }
}
