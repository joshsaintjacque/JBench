import Foundation
import Testing
@testable import JBenchCore

struct DomainModelsTests {
    @Test func presetRequiresTwoToSixAgents() throws {
        let configuration = AgentConfiguration(harness: .fake, model: "one")
        #expect(throws: JBenchCoreError.self) { try Preset(name: "Too few", agents: [configuration]) }
        let preset = try Preset(name: "Valid", agents: [configuration, configuration])
        #expect(preset.agents.count == 2)
    }

    @Test func titleAndAggregateStateAreDeterministic() throws {
        let config = AgentConfiguration(harness: .fake, model: "m")
        let runID = UUID(); let agentID = UUID()
        let completed = AgentAttempt(agentRunID: agentID, number: 1, state: .completed, requested: config)
        let failed = AgentAttempt(agentRunID: agentID, number: 2, state: .failed, requested: config)
        let agent = AgentRun(id: agentID, runID: runID, displayOrder: 0, requested: config, attempts: [completed, failed])
        let other = AgentRun(runID: runID, displayOrder: 1, requested: config, attempts: [AgentAttempt(agentRunID: UUID(), number: 1, state: .completed, requested: config)])
        let run = try BenchmarkRun(id: runID, prompt: "  A\n prompt for testing  ", directoryPath: "/tmp", repositoryState: .cleanGit, executionMode: .readOnly, rawEvidenceDirectory: "/tmp/evidence", agents: [agent, other])
        #expect(run.title == "A prompt for testing")
        #expect(run.state == .partiallyCompleted)
        #expect(canTransition(from: .running, to: .completed))
        #expect(!canTransition(from: .completed, to: .running))
    }
}
