import Foundation

public struct AnnotatedDiff: Sendable, Equatable {
    /// The diff with every line of the new file prefixed by its line number.
    public let text: String
    /// New-file line numbers that appear in the diff, per path.
    public let lines: [String: Set<Int>]
    public let isTruncated: Bool

    public init(text: String, lines: [String: Set<Int>], isTruncated: Bool) {
        self.text = text
        self.lines = lines
        self.isTruncated = isTruncated
    }

    public func contains(path: String, line: Int) -> Bool {
        lines[path]?.contains(line) == true
    }
}

/// Rewrites a unified diff so a reader never has to count lines from hunk headers.
public enum DiffAnnotator {
    public static func annotate(_ diff: String, maxBytes: Int = 300_000) -> AnnotatedDiff {
        var output: [String] = []
        var size = 0
        var lines: [String: Set<Int>] = [:]
        var path: String?
        var oldPath: String?
        var newLine = 0
        var inHunk = false
        var truncated = false

        func emit(_ line: String) -> Bool {
            size += line.utf8.count + 1
            guard size <= maxBytes else { return false }
            output.append(line)
            return true
        }

        let source = diff.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in source.enumerated() {
            let line = String(raw)
            var ok = true

            if line.hasPrefix("diff --git ") {
                inHunk = false
                path = nil
                oldPath = nil
            } else if !inHunk, line.hasPrefix("--- ") {
                oldPath = name(line.dropFirst(4), prefix: "a/")
            } else if !inHunk, line.hasPrefix("+++ ") {
                if line.dropFirst(4).hasPrefix("/dev/null") {
                    path = oldPath
                    ok = emit("=== \(oldPath ?? "?") (deleted)")
                } else {
                    path = name(line.dropFirst(4), prefix: "b/")
                    ok = emit("=== \(path ?? "?")")
                }
            } else if !inHunk, line.hasPrefix("Binary files ") {
                ok = emit("=== (binary file, not shown)")
            } else if line.hasPrefix("@@") {
                // @@ -old,count +new,count @@
                let new = line.split(separator: " ").first { $0.hasPrefix("+") }
                newLine = new.flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 1
                inHunk = true
                ok = emit(line)
            } else if inHunk, let path {
                switch line.first {
                case "+":
                    lines[path, default: []].insert(newLine)
                    ok = emit(String(format: "%5d + ", newLine) + line.dropFirst())
                    newLine += 1
                case "-":
                    ok = emit("      - " + line.dropFirst())
                case "\\":
                    break
                default:
                    // A trailing empty element is the file's final newline, not a context line.
                    if line.isEmpty, index == source.count - 1 { break }
                    lines[path, default: []].insert(newLine)
                    ok = emit(String(format: "%5d   ", newLine) + line.dropFirst())
                    newLine += 1
                }
            }

            if !ok {
                truncated = true
                output.append("[diff truncated: too large to review in full]")
                break
            }
        }
        return AnnotatedDiff(text: output.joined(separator: "\n"), lines: lines, isTruncated: truncated)
    }

    private static func name(_ text: Substring, prefix: String) -> String {
        var name = text.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) ?? String(text)
        if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        return name
    }
}
