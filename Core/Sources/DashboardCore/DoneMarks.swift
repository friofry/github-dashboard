import Foundation
import Observation

/// Pull requests the user is finished with. Any later activity in a pull request brings it back.
@MainActor
@Observable
public final class DoneMarks {
    private var marks: [String: Date] { didSet { preferences.reviewDone = marks } }
    private let preferences: ReviewPreferences
    private let now: () -> Date

    public init(preferences: ReviewPreferences, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.now = now
        let cutoff = now().addingTimeInterval(-DashboardStore.seenRetention)
        marks = preferences.reviewDone.filter { $0.value > cutoff }
    }

    public func isDone(_ pullRequest: PullRequest) -> Bool {
        guard let date = marks[pullRequest.id] else { return false }
        return pullRequest.updatedAt <= date
    }

    public func set(_ pullRequest: PullRequest, _ isDone: Bool) {
        marks[pullRequest.id] = isDone ? now() : nil
    }
}
