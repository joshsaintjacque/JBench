import Testing
import Foundation
@testable import JBenchCore

struct OpenCodeAdapterTests {
    @Test func parsesServerURLFromStartupOutput() {
        let line = "opencode server listening on http://127.0.0.1:49321"
        #expect(OpenCodeWireParser.serverURL(from: line)?.absoluteString == "http://127.0.0.1:49321")
    }

    @Test func mapsTextObservedSettingsAndReportedMetrics() {
        let text = OpenCodeWireParser.parseEvent("""
        {"type":"message.part.updated","properties":{"part":{"type":"text","text":"Hello"}}}
        """)
        #expect(text.kind == .textDelta)
        #expect(text.text == "Hello")

        let observed = OpenCodeWireParser.parseEvent("""
        {"type":"message.updated","properties":{"info":{"providerID":"deepseek","modelID":"v4","tokens":{"input":12,"output":34},"cost":0.0025}}}
        """)
        #expect(observed.kind == .observed)
        #expect(observed.observed?.model.value == "deepseek/v4")
        #expect(observed.observed?.model.provenance == .harnessReported)
        #expect(observed.metrics?.inputTokens == 12)
        #expect(observed.metrics?.outputTokens == 34)
        #expect(observed.metrics?.costProvenance == .harnessReported)
        #expect(observed.observed?.reasoning == .unavailable)
    }

    @Test func mapsPermissionAndTerminalEventsWithoutChangingRawSemantics() {
        let permission = OpenCodeWireParser.parseEvent("""
        {"type":"permission.asked","properties":{"id":"permission-7","permission":{"type":"edit","description":"Edit Notes.md","path":"/tmp/Notes.md"}}}
        """)
        #expect(permission.kind == .permission)
        #expect(permission.permissionID == "permission-7")
        #expect(permission.permissionCategory == "edit")
        #expect(permission.targetPath == "/tmp/Notes.md")

        let completed = OpenCodeWireParser.parseEvent("""
        {"type":"session.status","properties":{"status":"idle"}}
        """)
        #expect(completed.kind == .completed)
        #expect(completed.isTerminal)

        let failed = OpenCodeWireParser.parseEvent("""
        {"type":"session.error","properties":{"error":{"message":"Provider failed"}}}
        """)
        #expect(failed.kind == .failed)
        #expect(failed.text == "Provider failed")
    }

    @Test func unwrapsV11818SSEPayloadEnvelopeForEveryTerminalAndStreamedShape() {
        let text = OpenCodeWireParser.parseEvent("""
        {"directory":"/workspace","payload":{"type":"message.part.updated","properties":{"part":{"type":"text","text":"wrapped text"}}}}
        """)
        #expect(text.kind == .textDelta)
        #expect(text.text == "wrapped text")

        let observed = OpenCodeWireParser.parseEvent("""
        {"directory":"/workspace","payload":{"type":"message.updated","properties":{"info":{"providerID":"deepseek","modelID":"v4","tokens":{"input":5,"output":8},"cost":0.1}}}}
        """)
        #expect(observed.kind == .observed)
        #expect(observed.observed?.model.value == "deepseek/v4")
        #expect(observed.metrics?.inputTokens == 5)
        #expect(observed.metrics?.outputTokens == 8)

        let permission = OpenCodeWireParser.parseEvent("""
        {"directory":"/workspace","payload":{"type":"permission.asked","properties":{"id":"permission-wrapped","permission":{"type":"bash","description":"Run a command"}}}}
        """)
        #expect(permission.kind == .permission)
        #expect(permission.permissionID == "permission-wrapped")
        #expect(permission.permissionCategory == "bash")

        let idle = OpenCodeWireParser.parseEvent("""
        {"directory":"/workspace","payload":{"type":"session.status","properties":{"status":"idle"}}}
        """)
        #expect(idle.kind == .completed)

        let error = OpenCodeWireParser.parseEvent("""
        {"directory":"/workspace","payload":{"type":"session.error","properties":{"error":{"message":"wrapped provider failure"}}}}
        """)
        #expect(error.kind == .failed)
        #expect(error.text == "wrapped provider failure")
    }

    @Test func discoveryPreservesNativeProviderModelAndLabels() {
        let entries = OpenCodeWireParser.catalogEntries(from: """
        {"all":[{"id":"deepseek","models":{"v4":{"name":"DeepSeek V4","reasoning":["low","whatever-highest"]}}}]}
        """, source: "fixture")
        #expect(entries.count == 1)
        #expect(entries.first?.nativeModelID == "deepseek/v4")
        #expect(entries.first?.displayName == "DeepSeek V4")
        #expect(entries.first?.nativeReasoningValues == ["low", "whatever-highest"])
        #expect(entries.first?.discoverySource == "fixture")
    }

    @Test func authStateOnlyClaimsWhatTheServerReports() {
        #expect(OpenCodeWireParser.authenticationStatus(from: "{\"status\":\"connected\"}", statusCode: 200) == .ready)
        #expect(OpenCodeWireParser.authenticationStatus(from: "{\"status\":\"disconnected\"}", statusCode: 200) == .missing)
        #expect(OpenCodeWireParser.authenticationStatus(from: "{}", statusCode: 200) == .unknown)
        #expect(OpenCodeWireParser.authenticationStatus(from: "{}", statusCode: 401) == .missing)
    }

    @Test func readOnlyCapabilityRequiresACompositionVerifiedSentinel() async {
        let unverified = OpenCodeAdapter()
        let configuration = AgentConfiguration(harness: .openCode, model: "deepseek/v4")
        let unavailable = await unverified.readOnlyCapability(for: configuration)
        #expect(unavailable.requiresSentinel == false)
        #expect(unavailable.mayStartReadOnlyRun == false)

        let verified = OpenCodeAdapter(verifiedReadOnlyContract: .init(succeeded: true, detail: "OpenCode 1.18.18 write-block sentinel passed"))
        let capability = await verified.readOnlyCapability(for: configuration)
        #expect(capability.requiresSentinel)
        #expect(capability.mayStartReadOnlyRun)
        #expect(capability.explanation.contains("1.18.18"))
    }

    @Test func ownedShutdownStopsOnlyTheLaunchedChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        #expect(process.isRunning)

        let result = await OpenCodeAdapter.terminateOwnedProcess(process)
        #expect(result.stoppedGracefully)
        #expect(process.isRunning == false)
    }
}
