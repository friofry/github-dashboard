import Foundation
import Observation

/// The reviews and lessons the app knows about, backed by the files in the review workspace.
@MainActor
@Observable
public final class ReviewLibrary {
    public private(set) var reviews: [String: Review] = [:]
    public private(set) var lessons: [String: URL] = [:]
    @ObservationIgnored private var diffs: [String: ParsedDiff] = [:]
    private let workspace: ReviewWorkspace

    public init(workspace: ReviewWorkspace) {
        self.workspace = workspace
    }

    /// Picks up from disk whatever exists for these pull requests, including reviews made outside the app.
    public func load(_ pullRequests: [PullRequest]) {
        for pullRequest in pullRequests {
            let repo = pullRequest.repository.nameWithOwner
            reviews[pullRequest.id] = workspace.loadReview(repo: repo, number: pullRequest.number)
            lessons[pullRequest.id] = workspace.latestLesson(repo: repo, number: pullRequest.number)
        }
    }

    public func directory(for pullRequest: PullRequest) -> URL {
        workspace.directory(repo: pullRequest.repository.nameWithOwner, number: pullRequest.number)
    }

    public func writeInputs(for pullRequest: PullRequest, diff: AnnotatedDiff) throws {
        try workspace.writeInputs(pullRequest: pullRequest, diff: diff)
        diffs[pullRequest.id] = nil
    }

    /// Stamps a fresh review with what it describes, checks each finding against the reviewed diff, and saves it.
    public func store(_ review: Review, for record: RunRecord, reviewedAt: Date) throws {
        var review = review
        let diff = workspace.loadDiff(repo: record.repo, number: record.number)
        for index in review.findings.indices {
            let finding = review.findings[index]
            review.findings[index].anchored = diff?.file(finding.path)?.lines
                .contains { $0.kind != .removed && $0.number == finding.line } ?? false
        }
        review.pr = .init(repo: record.repo, number: record.number, headSha: record.headSha, reviewedAt: reviewedAt)
        try workspace.save(review, repo: record.repo, number: record.number)
        reviews[record.pullRequestID] = review
    }

    /// Changes one finding of a stored review and saves the review.
    public func update(_ finding: Finding, in pullRequest: PullRequest, _ change: (inout Finding) -> Void) throws {
        guard var review = reviews[pullRequest.id],
              let index = review.findings.firstIndex(where: { $0.id == finding.id })
        else { return }
        change(&review.findings[index])
        reviews[pullRequest.id] = review
        try workspace.save(review, repo: pullRequest.repository.nameWithOwner, number: pullRequest.number)
    }

    public func refreshLesson(for pullRequest: PullRequest) {
        lessons[pullRequest.id] = workspace.latestLesson(repo: pullRequest.repository.nameWithOwner,
                                                         number: pullRequest.number)
    }

    /// The reviewed diff of a pull request, for showing code next to a finding. Read once and kept.
    public func diff(for pullRequest: PullRequest) -> ParsedDiff? {
        if let cached = diffs[pullRequest.id] { return cached }
        let loaded = workspace.loadDiff(repo: pullRequest.repository.nameWithOwner, number: pullRequest.number)
        diffs[pullRequest.id] = loaded
        return loaded
    }

    public func link(for finding: Finding, in pullRequest: PullRequest) -> URL? {
        GitHubLinks.line(repo: pullRequest.repository.nameWithOwner, number: pullRequest.number,
                         headSha: reviews[pullRequest.id]?.pr?.headSha, finding: finding)
    }
}
