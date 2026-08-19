import Testing
import Foundation
@testable import JBenchCore

@Suite struct FuzzyMatcherTests {
    @Test func emptyQueryReturnsAllItems() {
        let candidates = ["gpt-4o", "claude-3-5-sonnet", "gemini-2.5-flash"]
        let results = FuzzyMatcher.filter(query: "", candidates: candidates)
        #expect(results.count == 3)
        #expect(results.map(\.item) == candidates)
        #expect(results.allSatisfy { $0.score == 0 })
    }

    @Test func exactMatchScoresHighest() {
        let candidates = ["gpt-5", "gpt-5-sol", "custom-gpt-5"]
        let results = FuzzyMatcher.filter(query: "gpt-5", candidates: candidates)
        #expect(results.first?.item == "gpt-5")
        #expect((results.first?.score ?? 0) > (results.dropFirst().first?.score ?? 0))
    }

    @Test func wordBoundaryMatchesRankHigher() {
        let candidates = [
            "org-mix/something-kimi-extra",
            "mixlayer/qwen/qwen3.5-9b",
            "hpc-ai/moonshotai/kimi-k2.7-code"
        ]
        let results = FuzzyMatcher.filter(query: "kimi", candidates: candidates)
        #expect(results.count == 2)
        #expect(results.contains { $0.item == "hpc-ai/moonshotai/kimi-k2.7-code" })
    }

    @Test func multiTokenQueriesMatchAcrossDelimiters() {
        let candidates = [
            "hpc-ai/moonshotai/kimi-k2.7-code",
            "hpc-ai/deepseek/deepseek-v4-flash",
            "ai-router/gpt-5.6-sol"
        ]
        let results = FuzzyMatcher.filter(query: "kimi code", candidates: candidates)
        #expect(results.count == 1)
        #expect(results.first?.item == "hpc-ai/moonshotai/kimi-k2.7-code")
    }

    @Test func subsequenceFuzzyAcronymMatching() {
        let candidates = [
            "ai-router/gpt-5.6-sol",
            "hpc-ai/deepseek/deepseek-v4-flash",
            "hpc-ai/deepseek/deepseek-v4-pro"
        ]
        let results = FuzzyMatcher.filter(query: "dsv4f", candidates: candidates)
        #expect(results.count == 1)
        #expect(results.first?.item == "hpc-ai/deepseek/deepseek-v4-flash")
    }

    @Test func caseInsensitiveMatching() {
        let candidates = ["hpc-ai/anthropic/claude-opus-4.7", "hpc-ai/zai-org/glm-5.1"]
        let results = FuzzyMatcher.filter(query: "CLAUDE OPUS", candidates: candidates)
        #expect(results.count == 1)
        #expect(results.first?.item == "hpc-ai/anthropic/claude-opus-4.7")
    }

    @Test func nonMatchingQueryReturnsEmpty() {
        let candidates = ["gpt-4o", "claude-3-5-sonnet"]
        let results = FuzzyMatcher.filter(query: "nonexistent-model-xyz", candidates: candidates)
        #expect(results.isEmpty)
    }

    @Test func matchedRangesHighlightCorrectSubstrings() {
        let target = "hpc-ai/deepseek/deepseek-v4-pro"
        let match = FuzzyMatcher.match(query: "deepseek", in: target)
        #expect(match != nil)
        if let match {
            #expect(!match.matchedRanges.isEmpty)
            let matchedText = match.matchedRanges.map { String(target[$0]) }.joined()
            #expect(matchedText.lowercased() == "deepseek")
        }
    }

    @Test func complexDelimitedQueryMatchesCorrectly() {
        let candidates = [
            "hpc-ai/minimax/minimax-m2.5",
            "hpc-ai/deepseek/deepseek-v4-pro",
            "hpc-ai/openai/gpt-5.5",
            "hpc-ai/moonshotai/kimi-k2.5",
            "kenari/deepseek-v4-flash:free",
            "unorouter/deepseek-v4-pro:free",
            "opencode/deepseek-v4-flash-free"
        ]
        let results = FuzzyMatcher.filter(query: "deepseek-v4-free", candidates: candidates)
        #expect(results.count == 3)
        #expect(results.map(\.item).allSatisfy { $0.contains("free") && $0.contains("deepseek-v4") })
        #expect(!results.contains { $0.item == "hpc-ai/minimax/minimax-m2.5" })
        #expect(!results.contains { $0.item == "hpc-ai/openai/gpt-5.5" })
    }
}
