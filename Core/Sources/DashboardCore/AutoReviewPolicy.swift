import Foundation

/// Which pull requests get reviewed without being asked. Pure: it only decides.
public enum AutoReviewPolicy {
    public struct Decision: Equatable {
        /// The baseline to remember from now on.
        public var baseline: [String]
        /// Pull request ids to review now.
        public var start: [String]

        public init(baseline: [String], start: [String]) {
            self.baseline = baseline
            self.start = start
        }
    }

    /// - Parameters:
    ///   - baseline: review requests that already existed when auto-review was switched on; nil right after
    ///     switching on, in which case the current requests become the baseline and nothing starts.
    ///   - attempted: "id@sha" of earlier automatic attempts, so a failing review is not retried forever.
    public static func decide(requests: [PullRequest], reviewed: [PullRequest], baseline: [String]?,
                              attempted: Set<String>,
                              status: (PullRequest) -> ReviewCoordinator.Status) -> Decision {
        // Switching auto-review on must not review the whole backlog: only what arrives or changes afterwards.
        guard let baseline else { return Decision(baseline: requests.map(\.id), start: []) }
        let known = Set(baseline), requested = Set(requests.map(\.id))

        let start = (requests + reviewed).filter { pullRequest in
            guard !attempted.contains(attemptKey(pullRequest)) else { return false }
            switch status(pullRequest) {
            // A pull request the user already reviewed themselves is only re-reviewed, never reviewed from scratch.
            case .none: return requested.contains(pullRequest.id) && !known.contains(pullRequest.id)
            case .outdated: return true
            case .working, .current, .failed: return false
            }
        }
        return Decision(baseline: baseline, start: start.map(\.id))
    }

    public static func attemptKey(_ pullRequest: PullRequest) -> String {
        "\(pullRequest.id)@\(pullRequest.headRefOid)"
    }
}
