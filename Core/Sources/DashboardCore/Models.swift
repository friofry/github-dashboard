import Foundation

// MARK: - GraphQL payload

public struct Actor: Decodable, Hashable, Sendable {
    public let login: String
    let typename: String?

    public var isBot: Bool { typename == "Bot" }

    private enum CodingKeys: String, CodingKey {
        case login
        case typename = "__typename"
    }
}

struct GitAuthor: Decodable, Sendable {
    let name: String?
    let user: Actor?
}

public struct Repository: Decodable, Hashable, Sendable {
    public let nameWithOwner: String
}

struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    let nodes: [Node?]
}

struct Commit: Decodable, Sendable {
    struct Rollup: Decodable, Sendable { let state: String }
    struct Parents: Decodable, Sendable { let totalCount: Int }

    let oid: String?
    let messageHeadline: String?
    let authoredDate: Date?
    let committedDate: Date?
    let additions: Int?
    let deletions: Int?
    let author: GitAuthor?
    let parents: Parents?
    let statusCheckRollup: Rollup?
}

struct CommitNode: Decodable, Sendable {
    let commit: Commit
}

/// Union of IssueComment / PullRequestReview / PullRequestCommit; fields absent on a type decode as nil.
struct TimelineItem: Decodable, Sendable {
    let typename: String
    let author: Actor?
    let createdAt: Date?
    let submittedAt: Date?
    let state: String?
    let bodyText: String?
    let url: URL?
    let commit: Commit?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case author, createdAt, submittedAt, state, bodyText, url, commit
    }
}

public struct PullRequest: Decodable, Identifiable, Sendable {
    public enum CIState: Sendable { case success, failure, pending }
    public enum ReviewDecision: Sendable { case approved, changesRequested }

    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let updatedAt: Date
    /// The head commit; a review made at another commit is out of date.
    public let headRefOid: String
    public let additions: Int
    public let deletions: Int
    public let repository: Repository
    public let author: Actor?
    let reviewDecision: String?
    let commits: Connection<CommitNode>
    let timelineItems: Connection<TimelineItem>

    public var ci: CIState? {
        switch commits.nodes.compactMap({ $0 }).last?.commit.statusCheckRollup?.state {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING", "EXPECTED": return .pending
        default: return nil
        }
    }

    public var decision: ReviewDecision? {
        switch reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: return nil
        }
    }
}

struct WeekPullRequest: Decodable, Sendable {
    let repository: Repository
    let commits: Connection<CommitNode>
}

// MARK: - Derived

public struct PREvent: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case comment
        case approved
        case changesRequested
        case reviewed
        case commit
    }

    public let id: String
    public let pullRequest: PullRequest
    public let kind: Kind
    public let actor: String
    public let isBot: Bool
    public let date: Date
    /// Comment or review body, or the commit headline. May be empty.
    public let text: String
    public let url: URL
}

extension PullRequest {
    public var events: [PREvent] {
        timelineItems.nodes.enumerated().compactMap { index, item in
            guard let item else { return nil }
            let id = "\(self.id)-\(index)-\(item.typename)"
            switch item.typename {
            case "IssueComment":
                guard let author = item.author, let date = item.createdAt, let url = item.url else { return nil }
                return PREvent(id: id, pullRequest: self, kind: .comment, actor: author.login, isBot: author.isBot,
                               date: date, text: item.bodyText ?? "", url: url)
            case "PullRequestReview":
                guard let author = item.author, let date = item.submittedAt, let url = item.url else { return nil }
                let kind: PREvent.Kind
                switch item.state {
                case "APPROVED": kind = .approved
                case "CHANGES_REQUESTED": kind = .changesRequested
                default: kind = .reviewed
                }
                return PREvent(id: id, pullRequest: self, kind: kind, actor: author.login, isBot: author.isBot,
                               date: date, text: item.bodyText ?? "", url: url)
            case "PullRequestCommit":
                guard let commit = item.commit, let date = commit.committedDate, let url = item.url else { return nil }
                let actor = commit.author?.user?.login ?? commit.author?.name ?? "unknown"
                return PREvent(id: id, pullRequest: self, kind: .commit, actor: actor, isBot: false,
                               date: date, text: commit.messageHeadline ?? "", url: url)
            default:
                return nil
            }
        }
    }
}

public struct Dashboard: Sendable {
    public let viewer: String
    /// Organizations the viewer belongs to, as far as the token is allowed to see.
    public let organizations: [String]
    public let tokenSource: TokenSource
    public let weekStart: Date
    public let mine: [PullRequest]
    public let mineTotal: Int
    public let reviews: [PullRequest]
    public let reviewsTotal: Int
}
