import Testing
@testable import JBenchCore

struct MarkdownOutlineTests {
    @Test
    func parsesPreambleAndAtxSections() {
        let sections = MarkdownOutlineParser.sections(in: """
        A short introduction.

        # Establish the domain
        Start with the core concepts.

        ## Define bounded contexts
        Keep boundaries explicit.
        """)

        #expect(sections.count == 3)
        #expect(sections[0].title == nil)
        #expect(sections[0].bodyMarkdown.contains("short introduction"))
        #expect(sections[1].title == "Establish the domain")
        #expect(sections[1].level == 1)
        #expect(sections[1].bodyMarkdown.contains("core concepts"))
        #expect(sections[2].title == "Define bounded contexts")
        #expect(sections[2].level == 2)
    }

    @Test
    func ignoresHeadingsInsideFencedCode() {
        let sections = MarkdownOutlineParser.sections(in: """
        # Real heading

        ```markdown
        # Not an outline item
        ```

        ## Another heading ###
        """)

        #expect(sections.map(\.title) == ["Real heading", "Another heading"])
        #expect(sections.map(\.id) == ["document-section-0", "document-section-1"])
    }

    @Test
    func keepsIndentedCodeAndTabIndentedLinesOutOfTheOutline() {
        let sections = MarkdownOutlineParser.sections(in: "# Real heading\n    # Four-space code heading\n\t# Tab-indented code heading\n   # Three-space heading\n## Next heading")

        #expect(sections.map(\.title) == ["Real heading", "Three-space heading", "Next heading"])
        #expect(sections[0].bodyMarkdown.contains("    # Four-space code heading"))
        #expect(sections[0].bodyMarkdown.contains("\t# Tab-indented code heading"))
    }

    @Test
    func keepsPlainTextAsOneSafeFallbackSection() {
        let sections = MarkdownOutlineParser.sections(in: "No headings here.")

        #expect(sections.count == 1)
        #expect(sections[0].id == "document")
        #expect(sections[0].title == nil)
        #expect(sections[0].markdown == "No headings here.")
        #expect(sections[0].bodyMarkdown == "No headings here.")
    }

    @Test
    func requiresMatchingFenceMarkerAndOpeningLength() {
        let sections = MarkdownOutlineParser.sections(in: "# Real\n````\n# hidden\n```\n# still hidden\n````\n## Visible")
        #expect(sections.map(\.title) == ["Real", "Visible"])
    }

    @Test
    func ignoresFourSpaceAndTabIndentedFenceLikeHeadings() {
        let sections = MarkdownOutlineParser.sections(in: "# Real\n    ```\n    # code\n    ```\n\t```\n\t# code\n\t```\n## Visible")
        #expect(sections.map(\.title) == ["Real", "Visible"])
    }
}
