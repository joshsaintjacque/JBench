import Foundation

public enum JudgeVoteResultSummary {
    public static func text(
        votes: [JudgeVote],
        candidateLabels: [String],
        configuredJudges: [JudgeConfiguration] = [],
        validCandidateIDs: Set<UUID>? = nil
    ) -> String? {
        guard !configuredJudges.isEmpty || !votes.isEmpty else { return nil }

        let configuredJudgeIDs = Set(configuredJudges.map(\.id))
        let applicableVotes = configuredJudges.isEmpty
            ? votes
            : votes.filter { configuredJudgeIDs.contains($0.judge.id) }
        let castVotes = applicableVotes.filter { vote in
            guard vote.errorMessage == nil,
                  vote.winningAgentRunID != nil,
                  !(vote.winningBlindLabel?.isEmpty ?? true) else { return false }
            if let validCandidateIDs, let winningAgentRunID = vote.winningAgentRunID {
                return validCandidateIDs.contains(winningAgentRunID)
            }
            return true
        }
        let noVoteCount: Int
        if configuredJudges.isEmpty {
            noVoteCount = max(0, votes.count - castVotes.count)
        } else {
            noVoteCount = max(0, configuredJudges.count - Set(castVotes.map(\.judge.id)).count)
        }

        let judgeCount = configuredJudges.isEmpty ? votes.count : configuredJudges.count
        guard !castVotes.isEmpty else {
            return judgeCount == 1 ? "Judge vote: No vote" : "Judge votes: No votes"
        }

        let candidateCounts = Dictionary(
            grouping: castVotes.compactMap(\.winningBlindLabel),
            by: { $0 }
        ).mapValues(\.count)
        var labels = Set(candidateLabels)
        labels.formUnion(candidateCounts.keys)
        let ranked = labels.sorted { lhs, rhs in
            let leftCount = candidateCounts[lhs] ?? 0
            let rightCount = candidateCounts[rhs] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, candidateCounts[$0] ?? 0) }
        let positiveRanked = ranked.filter { $0.1 > 0 }
        guard let first = positiveRanked.first else { return "Judge vote: No vote" }
        let top = positiveRanked.filter { $0.1 == first.1 }
        let result: String
        if top.count > 1 {
            let labels = top.map(\.0)
            result = labels.count == 2
                ? "Tie \(labels[0]) and \(labels[1]) \(first.1)-\(first.1)"
                : "Tie \(joinedLabels(labels)) \(first.1) each"
        } else if noVoteCount == 0 {
            let runnerUp = positiveRanked.dropFirst().first?.1 ?? 0
            result = runnerUp > 0
                ? "\(first.0) leads \(first.1)-\(runnerUp)"
                : "\(first.0) wins \(first.1)-0"
        } else if positiveRanked.count > 1 {
            result = "\(first.0) leads \(first.1)-\(positiveRanked[1].1)"
        } else {
            result = "\(first.0) has \(first.1) \(first.1 == 1 ? "vote" : "votes")"
        }

        let suffix = noVoteCount == 0
            ? ""
            : " · \(noVoteCount) no \(noVoteCount == 1 ? "vote" : "votes")"
        return "Judge \(castVotes.count == 1 ? "vote" : "votes"): \(result)\(suffix)"
    }

    private static func joinedLabels(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default: return labels.dropLast().joined(separator: ", ") + ", and \(labels.last!)"
        }
    }
}
