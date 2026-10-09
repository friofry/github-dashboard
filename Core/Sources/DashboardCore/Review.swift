import CryptoKit
import Foundation

/// One problem found in a pull request, in the form the `pr-review` skill defines.
public struct Finding: Codable, Identifiable, Sendable, Equatable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case regression, security, reliability, modularity, structure, smell
    }

    public enum Severity: String, Codable, CaseIterable, Sendable {
        case high, medium, low
    }

    /// How the problem comes about, as two to four short steps; the last one is the failure.
    public struct Step: Codable, Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    /// A concrete situation shown as "what each thing is now" against "what it is after the fix".
    public struct Scenario: Codable, Sendable, Equatable {
        public struct Row: Codable, Sendable, Equatable {
            public let item: String
            public let now: String
            public let nowOk: Bool
            public let after: String
            public let afterOk: Bool
        }

        public let title: String
        public let rows: [Row]
    }

    /// Claude's own estimate on three 1-3 scales. Rough by nature; the explanation carries more weight.
    public struct Impact: Codable, Sendable, Equatable {
        public let harm: Int
        public let harmNote: String
        public let likelihood: Int
        public let likelihoodNote: String
        public let effort: Int
        public let effortNote: String
    }

    public let category: Category
    public let severity: Severity
    public let title: String
    public let path: String
    public let line: Int
    public let endLine: Int?
    public let problem: String
    public let example: String?
    public let suggestion: String
    /// Ready to post on GitHub. The user may edit it before publishing.
    public var comment: String
    public let chain: [Step]?
    public let scenario: Scenario?
    public let impact: Impact?
    /// Set by the app: whether `path:line` is part of the diff, so GitHub can anchor a comment there.
    public var anchored: Bool?
    /// Set by the app once the user has published the comment: where it is on GitHub.
    public var postedURL: URL?

    public var id: String { "\(path):\(line):\(title)" }
}

public struct Review: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case approve, comment
        case requestChanges = "request_changes"
    }

    /// Which pull request and commit the review describes. Absent in reviews written by hand without it.
    public struct Subject: Codable, Sendable, Equatable {
        public let repo: String
        public let number: Int
        public let headSha: String
        public var reviewedAt: Date?
    }

    /// Background for a reviewer who does not know this part of the code. Absent in reviews made before it existed.
    public struct Context: Codable, Sendable, Equatable {
        /// Why the change is made.
        public let why: String
        /// Where the touched code sits in the project.
        public let architecture: String
        /// The feature the change goes into, explained very simply.
        public let feature: String
    }

    public let summary: String
    public let context: Context?
    public let verdict: Verdict
    public var findings: [Finding]
    public var pr: Subject?

    /// Most severe first; within a severity, in the skill's category order.
    public var sortedFindings: [Finding] {
        let severities = Finding.Severity.allCases, categories = Finding.Category.allCases
        return findings.sorted {
            let lhs = (severities.firstIndex(of: $0.severity) ?? 0, categories.firstIndex(of: $0.category) ?? 0)
            let rhs = (severities.firstIndex(of: $1.severity) ?? 0, categories.firstIndex(of: $1.category) ?? 0)
            return lhs < rhs
        }
    }
}

public enum GitHubLinks {
    /// Link to a line of a pull request. Built here, never taken from the model, so it can only point at github.com.
    public static func line(repo: String, number: Int, headSha: String?, finding: Finding) -> URL? {
        let allowed = CharacterSet.urlPathAllowed
        guard let repoPath = repo.addingPercentEncoding(withAllowedCharacters: allowed),
              let filePath = finding.path.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }

        if finding.anchored == false, let headSha, !headSha.isEmpty {
            return URL(string: "https://github.com/\(repoPath)/blob/\(headSha)/\(filePath)#L\(finding.line)")
        }
        // GitHub names a file's diff by the SHA-256 of its path; R<line> is a line on the new side.
        let anchor = SHA256.hash(data: Data(finding.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://github.com/\(repoPath)/pull/\(number)/files#diff-\(anchor)R\(finding.line)")
    }
}

/// The skill's files that the app needs at run time.
public struct ReviewSkill: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func schema() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("review.schema.json"), encoding: .utf8)
    }

    public func lessonPrompt(repo: String, number: Int, title: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("LESSON-PROMPT.md"), encoding: .utf8)
            .replacingOccurrences(of: "{{repo}}", with: repo)
            .replacingOccurrences(of: "{{number}}", with: String(number))
            .replacingOccurrences(of: "{{title}}", with: title)
    }
}

public enum ReviewInput {
    static let closingTag = "</pr-review-input>"
    /// The description explains why; past this it is usually pasted logs or templates.
    static let descriptionLimit = 4000

    /// The block the skill reads. The diff is other people's text, so it cannot be allowed to close the block early.
    public static func make(pullRequest: PullRequest, language: String, diff: AnnotatedDiff) -> String {
        var meta: [String: Any] = [
            "repo": pullRequest.repository.nameWithOwner,
            "number": pullRequest.number,
            "title": pullRequest.title,
            "author": pullRequest.author?.login ?? "",
            "headSha": pullRequest.headRefOid,
        ]
        if let body = pullRequest.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            meta["description"] = body.count > descriptionLimit ? String(body.prefix(descriptionLimit)) + "…" : body
        }
        if !language.isEmpty { meta["language"] = language }
        if diff.isTruncated { meta["note"] = "The diff was too large and is cut short." }
        let json = (try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let safe = { (text: String) in text.replacingOccurrences(of: closingTag, with: "</pr-review-input_>") }
        return "<pr-review-input>\n\(safe(json))\n\n\(safe(diff.text))\n\(closingTag)\n"
    }
}
