import Foundation
import Observation

public protocol CommentPublisher: Sendable {
    /// Posts the finding's comment on the pull request and returns where it landed.
    func publish(_ finding: Finding, repo: String, number: Int, commitSha: String) async throws -> URL
    /// Posts the comments of several findings as one review, so the author gets one notification, and returns
    /// where the review is. GitHub takes a review whole or not at all: `DashboardError.http(422)` means it
    /// could not attach one of the comments and nothing was posted.
    func publishReview(_ findings: [Finding], repo: String, number: Int, commitSha: String) async throws -> URL
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
        await post(finding, in: pullRequest, with: publisher)
    }

    /// What "publish all" would post now: the stored findings of severity medium or high without a comment
    /// on GitHub yet, most severe first.
    public func unpublished(in pullRequest: PullRequest) -> [Finding] {
        library.reviews[pullRequest.id]?.sortedFindings.filter { $0.severity != .low && $0.postedURL == nil } ?? []
    }

    /// Posts every finding of `unpublished(in:)` as the user. Only ever called from an explicit, confirmed click.
    /// Findings on lines of the diff go as one review; when GitHub refuses the review, and for the rest,
    /// each goes by itself, so one failure does not stop the others.
    public func publishAll(in pullRequest: PullRequest) async {
        guard let publisher else { return }
        let findings = unpublished(in: pullRequest).filter { inFlight.insert(Self.key($0, in: pullRequest)).inserted }
        defer { for finding in findings { inFlight.remove(Self.key(finding, in: pullRequest)) } }
        for finding in findings { errors[Self.key(finding, in: pullRequest)] = nil }

        var single = findings
        let commit = commit(for: pullRequest)
        let batch = findings.filter { $0.anchored != false }
        if batch.count > 1, !commit.isEmpty {
            do {
                let url = try await publisher.publishReview(batch, repo: pullRequest.repository.nameWithOwner,
                                                            number: pullRequest.number, commitSha: commit)
                single.removeAll { $0.anchored != false }
                for finding in batch { remember(url, for: finding, in: pullRequest) }
            } catch DashboardError.http(422) {
                // Nothing was posted; one by one, each comment finds the place GitHub accepts.
            } catch {
                // The review may exist on GitHub all the same, so posting again could duplicate it.
                single.removeAll { $0.anchored != false }
                for finding in batch { errors[Self.key(finding, in: pullRequest)] = error.localizedDescription }
            }
        }
        for finding in single { await post(finding, in: pullRequest, with: publisher) }
    }

    private func commit(for pullRequest: PullRequest) -> String {
        library.reviews[pullRequest.id]?.pr?.headSha ?? pullRequest.headRefOid
    }

    private func post(_ finding: Finding, in pullRequest: PullRequest, with publisher: CommentPublisher) async {
        let key = Self.key(finding, in: pullRequest)
        errors[key] = nil
        do {
            let url = try await publisher.publish(finding, repo: pullRequest.repository.nameWithOwner,
                                                  number: pullRequest.number, commitSha: commit(for: pullRequest))
            remember(url, for: finding, in: pullRequest)
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    /// Kept in the review file, so the comment cannot be posted twice after a restart.
    private func remember(_ url: URL, for finding: Finding, in pullRequest: PullRequest) {
        do {
            try library.update(finding, in: pullRequest) { $0.postedURL = url }
        } catch {
            errors[Self.key(finding, in: pullRequest)] = error.localizedDescription
        }
    }
}
