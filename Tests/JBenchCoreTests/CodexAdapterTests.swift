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
        #expect(params["sandboxPolicy"] as? [String: String] == ["type": "readOnly"])
        let input = try #require(params["input"] as? [[String: String]])
        #expect(input == [["type": "text", "text": "Return the exact heading only."]])

        let threadParams = CodexWireRequest.threadStartParams(for: request)
        #expect(threadParams["sandbox"] as? String == "readOnly")
        #expect(CodexWireRequest.approvalPolicy(for: .askEveryTime) == "on-request")
        #expect(CodexWireRequest.approvalPolicy(for: .allowForAttempt) == "on-request")
        #expect(CodexWireRequest.approvalPolicy(for: .denyAll) == "never")
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
}
