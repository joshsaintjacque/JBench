import Foundation
import Testing
@testable import JBenchCore

struct JudgeVoteResultSummaryTests {
    @Test func usesWinnerVersusZeroForThreeCandidatePlurality() {
        let judges = [judge(name: "One"), judge(name: "Two")]
        let votes = judges.map { vote(judge: $0, label: "B") }

        #expect(summary(votes: votes, labels: ["A", "B", "C"], judges: judges) == "Judge votes: B wins 2-0")
    }

    @Test func usesTopAndRunnerUpForMultiCandidatePlurality() {
        let judges = [judge(name: "One"), judge(name: "Two"), judge(name: "Three")]
        let votes = [
            vote(judge: judges[0], label: "B"),
            vote(judge: judges[1], label: "B"),
            vote(judge: judges[2], label: "A")
        ]

        #expect(summary(votes: votes, labels: ["A", "B", "C"], judges: judges) == "Judge votes: B leads 2-1")
    }

    @Test func reportsTie() {
        let judges = [judge(name: "One"), judge(name: "Two")]
        let votes = [vote(judge: judges[0], label: "A"), vote(judge: judges[1], label: "B")]

        #expect(summary(votes: votes, labels: ["A", "B", "C"], judges: judges) == "Judge votes: Tie A and B 1-1")
    }

    @Test func countsFailedAndMissingConfiguredJudgesAsNoVotes() {
        let judges = [judge(name: "One"), judge(name: "Two"), judge(name: "Three")]
        let votes = [
            vote(judge: judges[0], label: "B"),
            vote(judge: judges[1], label: nil, error: "judge failed")
        ]

        #expect(summary(votes: votes, labels: ["A", "B", "C"], judges: judges) == "Judge vote: B has 1 vote · 2 no votes")
    }

    @Test func reportsNoVotesWhenConfiguredJudgesHaveNoRecords() {
        let judges = [judge(name: "One"), judge(name: "Two")]

        #expect(summary(votes: [], labels: ["A", "B", "C"], judges: judges) == "Judge votes: No votes")
    }

    private func summary(votes: [JudgeVote], labels: [String], judges: [JudgeConfiguration]) -> String? {
        JudgeVoteResultSummary.text(votes: votes, candidateLabels: labels, configuredJudges: judges)
    }

    private func judge(name: String) -> JudgeConfiguration {
        .init(name: name, harness: .fake, model: "judge")
    }

    private func vote(judge: JudgeConfiguration, label: String?, error: String? = nil) -> JudgeVote {
        .init(
            runID: UUID(),
            judge: judge,
            winningAgentRunID: label == nil ? nil : UUID(),
            winningBlindLabel: label,
            errorMessage: error
        )
    }
}
