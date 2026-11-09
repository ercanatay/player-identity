import Foundation

/// Turns a GitHub release body (Markdown) into a displayable `AttributedString`.
/// Block structure (headings, fences, bullets) is resolved line by line; inline styles and links use
/// Foundation's Markdown parser. Anything unparsable falls back to plain text.
enum ReleaseNotesFormatter {
    static let maxLength = 4000

    /// Heading lines carry a `PresentationIntent` header; fenced code lines carry `.code`.
    static func attributed(_ markdown: String) -> AttributedString {
        let lines = Self.truncated(markdown).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result = AttributedString()
        var inFence = false
        var previousBlank = true // drops leading blank lines too
        var first = true
        var identity = 0

        func append(_ line: AttributedString) {
            if !first { result.append(AttributedString("\n")) }
            result.append(line)
            first = false
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t").union(.init(charactersIn: "\r")))
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                var code = AttributedString(raw)
                code.inlinePresentationIntent = .code
                append(code)
                previousBlank = false
                continue
            }
            if line.isEmpty {
                if !previousBlank { append(AttributedString("")) }
                previousBlank = true
                continue
            }
            previousBlank = false
            if let (level, text) = heading(line) {
                identity += 1
                var title = inline(text)
                title.presentationIntent = PresentationIntent(.header(level: level), identity: identity)
                title.inlinePresentationIntent = .stronglyEmphasized
                append(title)
            } else if let bullet = bulletText(line) {
                append(AttributedString("• ") + inline(bullet))
            } else {
                append(inline(line))
            }
        }
        // Trailing blank line left by the collapse step.
        while result.characters.last == "\n" { result.characters.removeLast() }
        return result
    }

    /// Body capped at `maxLength` characters, cut at the last line end and marked with "…".
    static func truncated(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = String(text.prefix(maxLength - 1))
        if let newline = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: newline) > 0 {
            return String(head[..<newline]) + "\n…"
        }
        return head + "…"
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
