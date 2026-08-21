import Foundation

internal struct MarkdownFence: Sendable, Hashable {
    let marker: Character
    let length: Int
    let trailingWhitespace: Bool

    func closes(_ opening: MarkdownFence) -> Bool {
        marker == opening.marker && length >= opening.length && trailingWhitespace
    }
}

internal enum MarkdownFenceParser {
    static func fence(in line: String) -> MarkdownFence? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " " { index += 1 }
        guard index <= 3, index < characters.count, characters[index] == "`" || characters[index] == "~" else { return nil }
        let marker = characters[index]
        var length = 0
        while index < characters.count, characters[index] == marker {
            length += 1
            index += 1
        }
        guard length >= 3 else { return nil }
        return MarkdownFence(marker: marker, length: length, trailingWhitespace: characters[index...].allSatisfy(\.isWhitespace))
    }
}

public struct MarkdownOrderedListItem: Hashable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum MarkdownResponseBlock: Hashable, Sendable {
    case paragraph(String)
    case unorderedList([String])
    case orderedList([MarkdownOrderedListItem])
    case code(language: String, value: String)
}

public enum MarkdownResponseParser {
    public static func parse(_ markdown: String) -> [MarkdownResponseBlock] {
        var blocks: [MarkdownResponseBlock] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [MarkdownOrderedListItem] = []
        var fence: MarkdownFence?
        var codeLanguage = ""
        var codeLines: [String] = []
        var indentedCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }
        func flushLists() {
            if !unordered.isEmpty { blocks.append(.unorderedList(unordered)); unordered.removeAll(keepingCapacity: true) }
            if !ordered.isEmpty { blocks.append(.orderedList(ordered)); ordered.removeAll(keepingCapacity: true) }
        }
        func flushCode() {
            blocks.append(.code(language: codeLanguage, value: codeLines.joined(separator: "\n")))
            codeLanguage = ""
            codeLines.removeAll(keepingCapacity: true)
        }
        func endIndentedCode() {
            guard indentedCode else { return }
            indentedCode = false
            while codeLines.last == "" { codeLines.removeLast() }
            flushCode()
        }

        for line in markdown.components(separatedBy: "\n") {
            if let currentFence = fence {
                if let closing = MarkdownFenceParser.fence(in: line), closing.closes(currentFence) {
                    fence = nil
                    flushCode()
                } else { codeLines.append(line) }
                continue
            }

            if indentedCode {
                if line.isEmpty || line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    codeLines.append("")
                    continue
                }
                if let indentation = codeIndentation(in: line) {
                    codeLines.append(String(line.dropFirst(indentation)))
                    continue
                }
                endIndentedCode()
            }

            if let opening = MarkdownFenceParser.fence(in: line) {
                flushParagraph(); flushLists()
                fence = opening
                let chars = Array(line)
                let markerIndex = chars.firstIndex(of: opening.marker) ?? 0
                codeLanguage = String(chars[(markerIndex + opening.length)...]).trimmingCharacters(in: .whitespaces)
                codeLines.removeAll(keepingCapacity: true)
                continue
            }

            if let indentation = codeIndentation(in: line) {
                flushParagraph(); flushLists()
                indentedCode = true
                codeLines.append(String(line.dropFirst(indentation)))
                continue
            }

            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { flushParagraph(); flushLists(); continue }
            if let item = listItem(in: content, marker: "-") ?? listItem(in: content, marker: "*") ?? listItem(in: content, marker: "+") {
                flushParagraph(); if !ordered.isEmpty { flushLists() }; unordered.append(item); continue
            }
            if let item = orderedListItem(in: content) {
                flushParagraph(); if !unordered.isEmpty { flushLists() }; ordered.append(item); continue
            }
            if !unordered.isEmpty || !ordered.isEmpty { flushLists() }
            paragraph.append(content)
        }

        if fence != nil || indentedCode != false { flushCode() }
        flushParagraph(); flushLists()
        return blocks
    }

    private static func codeIndentation(in line: String) -> Int? {
        if line.first == "\t" { return 1 }
        let count = line.prefix(while: { $0 == " " }).count
        return count >= 4 ? 4 : nil
    }
    private static func listItem(in line: String, marker: Character) -> String? {
        let prefix = "\(marker) "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    private static func orderedListItem(in line: String) -> MarkdownOrderedListItem? {
        let chars = Array(line)
        var index = 0
        while index < chars.count, chars[index].isNumber { index += 1 }
        guard index > 0, index + 1 < chars.count, chars[index] == "." || chars[index] == ")", chars[index + 1] == " " else { return nil }
        return MarkdownOrderedListItem(label: String(chars[..<(index + 1)]), value: String(chars[(index + 2)...]).trimmingCharacters(in: .whitespaces))
    }
}
