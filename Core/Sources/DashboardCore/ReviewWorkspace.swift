import Foundation

/// Where a pull request's review and lesson live on disk: `<root>/<repo>/pr-<number>/`.
public struct ReviewWorkspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(repo: String, number: Int) -> URL {
        // Only the repository name, and only characters GitHub allows in one, so the path cannot leave the root.
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let safe = String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return root
            .appendingPathComponent(safe.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "_" : safe)
            .appendingPathComponent("pr-\(number)")
    }

    public func loadReview(repo: String, number: Int) -> Review? {
        let file = directory(repo: repo, number: number).appendingPathComponent("review.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(Review.self, from: data)
    }

    public func save(_ review: Review, repo: String, number: Int) throws {
        let directory = directory(repo: repo, number: number)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(review).write(to: directory.appendingPathComponent("review.json"), options: .atomic)
    }

    /// The annotated diff saved when the pull request was reviewed.
    public func loadDiff(repo: String, number: Int) -> ParsedDiff? {
        let file = directory(repo: repo, number: number).appendingPathComponent("pr.diff")
        return (try? String(contentsOf: file, encoding: .utf8)).map(ParsedDiff.init(annotated:))
    }

    /// What the lesson is built from, next to the review.
    public func writeInputs(pullRequest: PullRequest, diff: AnnotatedDiff) throws {
        let repo = pullRequest.repository.nameWithOwner
        let directory = directory(repo: repo, number: pullRequest.number)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "repo": repo, "number": pullRequest.number, "title": pullRequest.title,
            "url": pullRequest.url.absoluteString, "author": pullRequest.author?.login ?? "",
            "headSha": pullRequest.headRefOid,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("pr.json"), options: .atomic)
        try Data(diff.text.utf8).write(to: directory.appendingPathComponent("pr.diff"), options: .atomic)
    }

    public func latestLesson(repo: String, number: Int) -> URL? {
        let lessons = directory(repo: repo, number: number).appendingPathComponent("lessons")
        let files = (try? FileManager.default.contentsOfDirectory(at: lessons, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "html" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
