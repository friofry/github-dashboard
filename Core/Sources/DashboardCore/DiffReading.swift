import Foundation

public struct CodeLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed }

    /// Line number in the new file; removed lines have none.
    public let number: Int?
    public let kind: Kind
    public let text: String
}

/// One file of a pull request, read back from the annotated diff the app saved next to the review.
public struct DiffFile: Equatable, Sendable {
    public let path: String
    public let lines: [CodeLine]

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
    /// The last new-file line the diff shows; the scale for drawing where changes sit.
    public var lastLine: Int { lines.compactMap(\.number).max() ?? 0 }

    /// Runs of consecutive added lines.
    public var changedRanges: [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for number in lines.filter({ $0.kind == .added }).compactMap(\.number) {
            if let last = ranges.last, number == last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...number
            } else {
                ranges.append(number...number)
            }
        }
        return ranges
    }
}

public struct ParsedDiff: Equatable, Sendable {
    public let files: [DiffFile]

    /// - Parameter annotated: text produced by `DiffAnnotator`.
    public init(annotated: String) {
        var files: [DiffFile] = []
        var path: String?
        var lines: [CodeLine] = []
        func close() {
            if let path { files.append(DiffFile(path: path, lines: lines)) }
            lines = []
        }

        for raw in annotated.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("=== ") {
                close()
                let name = raw.dropFirst(4)
                path = name.hasPrefix("(binary") ? nil
                    : String(name.hasSuffix(" (deleted)") ? name.dropLast(10) : name)
            } else if path != nil, !raw.hasPrefix("@@"), !raw.hasPrefix("[diff truncated"), raw.count >= 8 {
                // "   12 + text", "   12   text" or "      - text": number in 5 columns, marker in the 7th.
                let marker = raw[raw.index(raw.startIndex, offsetBy: 6)]
                let number = Int(raw.prefix(5).trimmingCharacters(in: .whitespaces))
                let kind: CodeLine.Kind = marker == "+" ? .added : marker == "-" ? .removed : .context
                lines.append(CodeLine(number: number, kind: kind, text: String(raw.dropFirst(8))))
            }
        }
        close()
        self.files = files
    }

    public func file(_ path: String) -> DiffFile? {
        files.first { $0.path == path }
    }

    /// New-file lines `from...to` with a few lines of context on each side; empty when the diff does not show them.
    public func excerpt(path: String, from: Int, to: Int, context: Int = 2) -> [CodeLine] {
        guard let file = file(path) else { return [] }
        let wanted = (from - context)...(max(from, to) + context)
        let lines = file.lines.filter { $0.kind != .removed && $0.number.map(wanted.contains) == true }
        return lines.contains { $0.number == from } ? lines : []
    }
}

/// A review comment split into prose and fenced blocks, so it can be shown the way GitHub renders it.
public enum CommentPart: Equatable, Sendable {
    case text(String)
    /// `language` is "suggestion" for a GitHub suggested change.
    case code(language: String, body: String)

    public static func parse(_ markdown: String) -> [CommentPart] {
        var parts: [CommentPart] = []
        var text: [String] = []
        var code: [String]?
        var language = ""
        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { parts.append(.text(joined)) }
            text = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let body = code {
                    parts.append(.code(language: language, body: body.joined(separator: "\n")))
                    code = nil
                } else {
                    flushText()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                text.append(line)
            }
        }
        if let body = code { parts.append(.code(language: language, body: body.joined(separator: "\n"))) }
        flushText()
        return parts
    }

    /// The replacement lines of the first suggested change, if the comment has one.
    public static func suggestion(in markdown: String) -> [String]? {
        for part in parse(markdown) {
            if case .code("suggestion", let body) = part { return body.components(separatedBy: "\n") }
        }
        return nil
    }
}
