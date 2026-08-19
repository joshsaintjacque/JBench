import Foundation

public struct FuzzyMatchResult<T: Sendable>: Sendable {
    public let item: T
    public let score: Int
    public let matchedRanges: [Range<String.Index>]

    public init(item: T, score: Int, matchedRanges: [Range<String.Index>]) {
        self.item = item
        self.score = score
        self.matchedRanges = matchedRanges
    }
}

public enum FuzzyMatcher {
    /// Evaluates `query` against `target`. Returns a relevance score and matched character index ranges if matched.
    public static func match(query: String, in target: String) -> (score: Int, matchedRanges: [Range<String.Index>])? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return (score: 0, matchedRanges: [])
        }

        guard !target.isEmpty else {
            return nil
        }

        let lowerQuery = trimmedQuery.lowercased()

        // 1. Exact match (case-insensitive)
        if target.caseInsensitiveCompare(trimmedQuery) == .orderedSame {
            return (score: 1000, matchedRanges: [target.startIndex..<target.endIndex])
        }

        // 2. Exact prefix match
        if let prefixRange = target.range(of: trimmedQuery, options: [.caseInsensitive, .anchored]) {
            let baseScore = 800 - target.count
            return (score: max(500, baseScore), matchedRanges: [prefixRange])
        }

        // 3. Contiguous substring match
        if let subRange = target.range(of: trimmedQuery, options: .caseInsensitive) {
            let startOffset = target.distance(from: target.startIndex, to: subRange.lowerBound)
            var score = 600 - (startOffset * 4) - (target.count - trimmedQuery.count)
            // Word boundary bonus if starts after a delimiter
            if startOffset > 0 {
                let prevChar = target[target.index(before: subRange.lowerBound)]
                if ["/", "-", "_", ".", " ", ":", "@"].contains(prevChar) {
                    score += 160
                }
            }
            return (score: max(300, score), matchedRanges: [subRange])
        }

        // 4. Token-based matching (e.g. "kimi code" or "deepseek flash")
        let queryTokens = trimmedQuery.split { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "/" }.map { String($0) }
        if queryTokens.count > 1 {
            var allMatched = true
            var tokenRanges: [Range<String.Index>] = []
            var tokenScore = 400
            var searchStart = target.startIndex

            for token in queryTokens {
                if let range = target.range(of: token, options: .caseInsensitive, range: searchStart..<target.endIndex) ?? target.range(of: token, options: .caseInsensitive) {
                    tokenRanges.append(range)
                    let startOffset = target.distance(from: target.startIndex, to: range.lowerBound)
                    if startOffset > 0 {
                        let prevChar = target[target.index(before: range.lowerBound)]
                        if ["/", "-", "_", ".", " ", ":", "@"].contains(prevChar) {
                            tokenScore += 40
                        }
                    }
                    searchStart = range.upperBound
                } else {
                    allMatched = false
                    break
                }
            }

            if allMatched {
                tokenScore -= (target.count - trimmedQuery.count)
                return (score: max(200, tokenScore), matchedRanges: tokenRanges)
            }
        }

        // 5. Fuzzy Subsequence Matching (characters in sequential order)
        var targetIndex = target.startIndex
        var matchedIndices: [String.Index] = []
        var consecutiveStreak = 0
        var score = 120

        for queryChar in lowerQuery {
            var found = false
            while targetIndex < target.endIndex {
                let currentChar = target[targetIndex]
                let lowerCurrentChars = currentChar.lowercased()
                let isWordBoundary = (targetIndex == target.startIndex) ||
                    ["/", "-", "_", ".", " ", ":", "@"].contains(target[target.index(before: targetIndex)])

                if lowerCurrentChars.contains(queryChar) {
                    found = true
                    matchedIndices.append(targetIndex)

                    if isWordBoundary {
                        score += 35
                    }
                    if consecutiveStreak > 0 {
                        score += (consecutiveStreak * 15)
                    }
                    consecutiveStreak += 1

                    targetIndex = target.index(after: targetIndex)
                    break
                } else {
                    consecutiveStreak = 0
                    score -= 1
                    targetIndex = target.index(after: targetIndex)
                }
            }

            if !found {
                return nil
            }
        }

        let ranges = groupIndicesIntoRanges(matchedIndices, in: target)
        score -= (target.count - matchedIndices.count)
        return (score: max(1, score), matchedRanges: ranges)
    }

    private static func groupIndicesIntoRanges(_ indices: [String.Index], in target: String) -> [Range<String.Index>] {
        guard !indices.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var rangeStart = indices[0]
        var prevIndex = indices[0]

        for i in 1..<indices.count {
            let currIndex = indices[i]
            if target.index(after: prevIndex) == currIndex {
                prevIndex = currIndex
            } else {
                ranges.append(rangeStart..<target.index(after: prevIndex))
                rangeStart = currIndex
                prevIndex = currIndex
            }
        }
        ranges.append(rangeStart..<target.index(after: prevIndex))
        return ranges
    }

    /// Filters and sorts items based on matching a single string property.
    public static func filter<T: Sendable>(
        query: String,
        items: [T],
        targetKeyPath: KeyPath<T, String>
    ) -> [FuzzyMatchResult<T>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return items.map { FuzzyMatchResult(item: $0, score: 0, matchedRanges: []) }
        }

        var results: [FuzzyMatchResult<T>] = []
        for item in items {
            let targetString = item[keyPath: targetKeyPath]
            if let match = match(query: trimmed, in: targetString) {
                results.append(FuzzyMatchResult(item: item, score: match.score, matchedRanges: match.matchedRanges))
            }
        }

        return results.sorted { (lhs, rhs) in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.item[keyPath: targetKeyPath].localizedCaseInsensitiveCompare(rhs.item[keyPath: targetKeyPath]) == .orderedAscending
        }
    }

    /// Convenience for filtering a list of candidate strings.
    public static func filter(
        query: String,
        candidates: [String]
    ) -> [FuzzyMatchResult<String>] {
        filter(query: query, items: candidates, targetKeyPath: \.self)
    }
}
