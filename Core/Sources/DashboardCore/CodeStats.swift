import Foundation

/// Lines changed by the viewer since the start of the week.
public struct CodeStats: Sendable {
    public struct RepoRow: Identifiable, Sendable {
        public let repo: String
        public internal(set) var additions = 0
        public internal(set) var deletions = 0
        public internal(set) var commits = 0
        public var id: String { repo }
    }

    public struct DayRow: Identifiable, Sendable {
        public let day: Date
        public internal(set) var additions = 0
        public internal(set) var deletions = 0
        public var id: Date { day }
    }

    public internal(set) var additions = 0
    public internal(set) var deletions = 0
    public internal(set) var commits = 0
    public internal(set) var repos: [RepoRow] = []
    public internal(set) var days: [DayRow] = []
    /// True when the account has more pull requests this week than the app is willing to page through.
    public internal(set) var isPartial = false
}

extension CodeStats {
    static func weekStart(for now: Date, calendar: Calendar) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    init(pullRequests: [WeekPullRequest], viewer: String, weekStart: Date, calendar: Calendar) {
        var repos: [String: RepoRow] = [:]
        var days: [Date: DayRow] = [:]
        for offset in 0..<7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: weekStart) {
                days[day] = DayRow(day: day)
            }
        }

        var counted = Set<String>()
        for pullRequest in pullRequests {
            for node in pullRequest.commits.nodes {
                guard let commit = node?.commit,
                      let oid = commit.oid, let date = commit.authoredDate,
                      date >= weekStart,
                      commit.author?.user?.login == viewer,
                      // A merge commit's diff is taken against its first parent, i.e. everyone else's work.
                      (commit.parents?.totalCount ?? 1) <= 1,
                      counted.insert(oid).inserted
                else { continue }
                let added = commit.additions ?? 0, deleted = commit.deletions ?? 0

                additions += added
                deletions += deleted
                commits += 1

                let repo = pullRequest.repository.nameWithOwner
                repos[repo, default: RepoRow(repo: repo)].additions += added
                repos[repo]?.deletions += deleted
                repos[repo]?.commits += 1

                let day = calendar.startOfDay(for: date)
                days[day]?.additions += added
                days[day]?.deletions += deleted
            }
        }
        self.repos = repos.values.sorted { $0.additions + $0.deletions > $1.additions + $1.deletions }
        self.days = days.values.sorted { $0.day < $1.day }
    }
}
