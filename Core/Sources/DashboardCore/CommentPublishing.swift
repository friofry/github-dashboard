import Foundation
import Observation

public protocol CommentPublisher: Sendable {
    /// Posts the finding's comment on the pull request and returns where it landed.
    func publish(_ finding: Finding, repo: String, number: Int, commitSha: String) async throws -> URL
}

/// Editing a finding's comment and posting it to GitHub. The only part of the app that writes to GitHub.
@MainActor
@Observable
public final class CommentPublishing {
    /// Findings being published right now, and the last error per finding, by `key(_:in:)`.
    public private(set) var inFlight: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    private let publisher: CommentPublisher?
    private let library: ReviewLibrary

    public init(publisher: CommentPublisher?, library: ReviewLibrary) {
        self.publisher = publisher
        self.library = library
    }

    public static func key(_ finding: Finding, in pullRequest: PullRequest) -> String {
        "\(pullRequest.id)|\(finding.id)"
    }

    /// Replaces the text that Publish will post. A published comment can no longer be changed from here.
    public func setComment(_ text: String, for finding: Finding, in pullRequest: PullRequest) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? library.update(finding, in: pullRequest) { stored in
            if stored.postedURL == nil { stored.comment = trimmed }
        }
    }

    /// Posts one comment to GitHub as the user. Only ever called from an explicit, confirmed click.
    public func publish(_ finding: Finding, in pullRequest: PullRequest) async {
        let key = Self.key(finding, in: pullRequest)
        guard let publisher, finding.postedURL == nil, inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }
        errors[key] = nil
        do {
            let commit = library.reviews[pullRequest.id]?.pr?.headSha ?? pullRequest.headRefOid
            let url = try await publisher.publish(finding, repo: pullRequest.repository.nameWithOwner,
                                                  number: pullRequest.number, commitSha: commit)
            // Remembered in the review file, so the comment cannot be posted twice after a restart.
            try library.update(finding, in: pullRequest) { $0.postedURL = url }
        } catch {
            errors[key] = error.localizedDescription
        }
    }
}
