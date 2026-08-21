import Foundation

/// A deterministic, dependency-free representation of a Markdown document's
/// sections. The parser intentionally supports the common ATX heading form
/// (`# Heading`) and ignores headings inside fenced code blocks.
public struct MarkdownDocumentSection: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let level: Int
    public let markdown: String
    public let headingMarkdown: String?
    public let bodyMarkdown: String
    public let headingBlocks: [MarkdownResponseBlock]
    public let bodyBlocks: [MarkdownResponseBlock]

    public init(
        id: String,
        title: String?,
        level: Int,
        markdown: String,
        headingMarkdown: String? = nil,
        bodyMarkdown: String,
        headingBlocks: [MarkdownResponseBlock]? = nil,
        bodyBlocks: [MarkdownResponseBlock]? = nil
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.markdown = markdown
        self.headingMarkdown = headingMarkdown
        self.bodyMarkdown = bodyMarkdown
        self.headingBlocks = headingBlocks ?? (headingMarkdown.map(MarkdownResponseParser.parse) ?? [])
        self.bodyBlocks = bodyBlocks ?? MarkdownResponseParser.parse(bodyMarkdown.isEmpty ? markdown : bodyMarkdown)
    }
}

public enum MarkdownOutlineParser {
    /// Splits Markdown into a preamble plus heading-led sections.
    ///
    /// This is deliberately small. It does not attempt to be a complete
    /// Markdown parser; native `AttributedString(markdown:)` remains the
    /// renderer for each returned section.
    public static func sections(in markdown: String) -> [MarkdownDocumentSection] {
        let lines = markdown.components(separatedBy: "\n")
        var headings: [(line: Int, level: Int, title: String)] = []
        var fence: MarkdownFence?

        for (index, line) in lines.enumerated() {
            if let currentFence = fence {
                if let closingFence = MarkdownFenceParser.fence(in: line), closingFence.closes(currentFence) {
                    fence = nil
                }
                continue
            }

            if let openingFence = MarkdownFenceParser.fence(in: line) {
                fence = openingFence
                continue
            }

            if let heading = parseHeading(line) {
                headings.append((index, heading.level, heading.title))
            }
        }

        guard !headings.isEmpty else {
            return [
                MarkdownDocumentSection(
                    id: "document",
                    title: nil,
                    level: 0,
                    markdown: markdown,
                    bodyMarkdown: markdown
                )
            ]
        }

        var sections: [MarkdownDocumentSection] = []
        let firstHeadingLine = headings[0].line
        if lines[..<firstHeadingLine].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let preamble = lines[..<firstHeadingLine].joined(separator: "\n")
            sections.append(
                MarkdownDocumentSection(
                    id: "document-preamble",
                    title: nil,
                    level: 0,
                    markdown: preamble,
                    bodyMarkdown: preamble
                )
            )
        }

        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].line : lines.count
            let sectionLines = Array(lines[heading.line..<end])
            let sectionMarkdown = sectionLines.joined(separator: "\n")
            let headingMarkdown = sectionLines.first ?? ""
            let bodyMarkdown = sectionLines.dropFirst().joined(separator: "\n")
            sections.append(
                MarkdownDocumentSection(
                    id: "document-section-\(index)",
                    title: heading.title,
                    level: heading.level,
                    markdown: sectionMarkdown,
                    headingMarkdown: headingMarkdown,
                    bodyMarkdown: bodyMarkdown,
                    headingBlocks: MarkdownResponseParser.parse(headingMarkdown),
                    bodyBlocks: MarkdownResponseParser.parse(bodyMarkdown)
                )
            )
        }

        return sections
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        let characters = Array(line)
        var index = 0
        var leadingSpaces = 0
        while index < characters.count, characters[index] == " " {
            leadingSpaces += 1
            index += 1
        }
        guard leadingSpaces <= 3 else { return nil }

        var level = 0
        while index < characters.count, characters[index] == "#" {
            level += 1
            index += 1
        }
        guard (1...6).contains(level) else { return nil }
        guard index == characters.count || characters[index].isWhitespace else { return nil }

        let title = String(characters[index...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }
}
