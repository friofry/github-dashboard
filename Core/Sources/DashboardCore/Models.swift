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
    struct Rollup: Decodable, Sendable {
        let state: String
        /// Older saved data has none.
        let contexts: Connection<CheckContext>?
    }
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
    /// The description as plain text. Older saved data has none.
    public let bodyText: String?
    /// The branch the changes are on and the branch they go into. Older saved data has neither.
    public let headRefName: String?
    public let baseRefName: String?
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

    /// Every status and check run on the head commit.
    public var checks: [CheckContext] {
        commits.nodes.compactMap({ $0 }).last?.commit.statusCheckRollup?.contexts?.nodes.compactMap { $0 } ?? []
    }

    public var decision: ReviewDecision? {
        switch reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: return nil
        }
    }
}

/// One line of a commit's checks: a commit status (what Jenkins posts) or a GitHub check run.
public struct CheckContext: Decodable, Hashable, Sendable {
    public let name: String
    /// Nil while a check run is queued or in progress, and for states this app does not know.
    public let state: PullRequest.CIState?
    /// Where the check's details live, e.g. the Jenkins build.
    public let url: URL?

    public init(name: String, state: PullRequest.CIState?, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case context, state, targetUrl
        case name, status, conclusion, detailsUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(String.self, forKey: .typename) == "CheckRun" {
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            url = try? container.decodeIfPresent(URL.self, forKey: .detailsUrl)
            switch try container.decodeIfPresent(String.self, forKey: .conclusion) {
            case "SUCCESS", "NEUTRAL", "SKIPPED": state = .success
            case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED": state = .failure
            case nil: state = .pending
            default: state = nil
            }
        } else {
            name = try container.decodeIfPresent(String.self, forKey: .context) ?? ""
            url = try? container.decodeIfPresent(URL.self, forKey: .targetUrl)
            switch try container.decodeIfPresent(String.self, forKey: .state) {
            case "SUCCESS": state = .success
            case "FAILURE", "ERROR": state = .failure
            case "PENDING", "EXPECTED": state = .pending
            default: state = nil
            }
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
