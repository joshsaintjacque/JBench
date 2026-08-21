import Testing
@testable import JBenchCore

struct MarkdownResponseParserTests {
    @Test
    func preservesFenceLengthAndMarkerMatching() {
        let blocks = MarkdownResponseParser.parse("````swift\n# hidden\n`````\nprose")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .code(language: "swift", value: "# hidden"))
        #expect(blocks[1] == .paragraph("prose"))
    }

    @Test
    func rejectsTooShortTildeClosingFence() {
        let blocks = MarkdownResponseParser.parse("~~~~~\ntilde\n~~~\nstill code\n~~~~~~\nprose")
        #expect(blocks == [.code(language: "", value: "tilde\n~~~\nstill code"), .paragraph("prose")])
    }

    @Test
    func rejectsMismatchedClosingFenceMarker() {
        let blocks = MarkdownResponseParser.parse("```swift\ncode\n~~~\nstill code\n```\nprose")
        #expect(blocks == [.code(language: "swift", value: "code\n~~~\nstill code"), .paragraph("prose")])
    }

    @Test
    func handlesIndentedCodeWithoutTurningItIntoLists() {
        let blocks = MarkdownResponseParser.parse("    - item\n        nested\n\t1. numbered\nprose")
        #expect(blocks == [.code(language: "", value: "- item\n    nested\n1. numbered"), .paragraph("prose")])
    }

    @Test
    func preservesOrderedLabelsAndMarkerShapes() {
        let blocks = MarkdownResponseParser.parse("2. Two\n7) Seven")
        #expect(blocks == [.orderedList([
            MarkdownOrderedListItem(label: "2.", value: "Two"),
            MarkdownOrderedListItem(label: "7)", value: "Seven")
        ])])
    }

    @Test
    func transitionsFromIndentedCodeBackToProseAndCoexistsWithFences() {
        let blocks = MarkdownResponseParser.parse("    code\n\n    more\n\n```\nfenced\n```\nback")
        #expect(blocks == [
            .code(language: "", value: "code\n\nmore"),
            .code(language: "", value: "fenced"),
            .paragraph("back")
        ])
    }
}
