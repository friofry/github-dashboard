import Foundation

public enum DashboardError: LocalizedError, Equatable {
    case missingToken
    case unauthorized
    case http(Int)
    case cannotWrite
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "No GitHub token found. Add one in Settings."
        case .unauthorized: return "GitHub rejected the token. Check it in Settings."
        case .http(let code): return "GitHub API returned HTTP \(code)."
        case .cannotWrite: return "This token is not allowed to comment on that repository."
        case .graphQL(let message): return "GitHub API error: \(message)"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

public protocol DashboardService: Sendable {
    /// - Parameter orgs: limits every list to these owners (organizations or users); empty means all repositories.
    func fetchPullRequests(orgs: [String], now: Date) async throws -> Dashboard
    /// Open pull requests the viewer has already reviewed. GitHub drops the review request as soon as a review
    /// or a single review comment is submitted, so without this list a pull request vanishes mid-conversation.
    func fetchReviewed(orgs: [String]) async throws -> [PullRequest]
    /// Slower than the lists on busy accounts, so it is loaded separately.
    func fetchCodeStats(orgs: [String], now: Date) async throws -> CodeStats
}

/// Talks to the GitHub GraphQL API. Lists and weekly stats are separate requests:
/// asked for together they exceed GitHub's 10 second budget on busy accounts.
public struct GitHubService: DashboardService, PullRequestDiffSource, CommentPublisher {
    private static let endpoint = URL(string: "https://api.github.com/graphql")!
    static let statsPageSize = 50
    static let statsMaxPages = 6

    private let tokens: TokenProvider
    private let transport: HTTPTransport
    private let calendar: Calendar

    public init(tokens: TokenProvider, transport: HTTPTransport = URLSession.shared, calendar: Calendar = .current) {
        self.tokens = tokens
        self.transport = transport
        self.calendar = calendar
    }

    public func fetchPullRequests(orgs: [String], now: Date) async throws -> Dashboard {
        let token = try await requireToken()
        let scope = Self.scope(orgs)
        let payload: ListsPayload = try await post(Self.listsQuery, token: token, variables: [
            "mine": "is:pr is:open author:@me archived:false sort:updated-desc\(scope)",
            "reviews": "is:pr is:open review-requested:@me archived:false sort:updated-desc\(scope)",
        ])
        return Dashboard(
            viewer: payload.viewer.login,
            organizations: payload.viewer.organizations?.nodes.compactMap { $0?.login } ?? [],
            tokenSource: token.source,
            weekStart: CodeStats.weekStart(for: now, calendar: calendar),
            mine: payload.mine.nodes.compactMap { $0 },
            mineTotal: payload.mine.issueCount,
            reviews: payload.reviews.nodes.compactMap { $0 },
            reviewsTotal: payload.reviews.issueCount
        )
    }

    public func fetchReviewed(orgs: [String]) async throws -> [PullRequest] {
        let token = try await requireToken()
        let search = "is:pr is:open reviewed-by:@me -author:@me archived:false sort:updated-desc\(Self.scope(orgs))"
        let payload: ReviewedPayload = try await post(Self.reviewedQuery, token: token, variables: ["reviewed": search])
        return payload.reviewed.nodes.compactMap { $0 }
    }

    public func fetchCodeStats(orgs: [String], now: Date) async throws -> CodeStats {
        let token = try await requireToken()
        let weekStart = CodeStats.weekStart(for: now, calendar: calendar)

        // Search dates are UTC days; widen by a day and filter precisely by commit date afterwards.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let since = dayFormatter.string(from: weekStart.addingTimeInterval(-86_400))
        let search = "is:pr author:@me updated:>=\(since) sort:updated-desc\(Self.scope(orgs))"

        var pullRequests: [WeekPullRequest] = []
        var viewer = ""
        var cursor: String?
        var hasMore = true
        var pages = 0
        while hasMore, pages < Self.statsMaxPages {
            var variables: [String: Any] = ["week": search, "first": Self.statsPageSize]
            if let cursor { variables["after"] = cursor }
            let payload: StatsPayload = try await post(Self.statsQuery, token: token, variables: variables)
            viewer = payload.viewer.login
            pullRequests += payload.week.nodes.compactMap { $0 }
            cursor = payload.week.pageInfo?.endCursor
            hasMore = payload.week.pageInfo?.hasNextPage == true && cursor != nil
            pages += 1
        }

        var stats = CodeStats(pullRequests: pullRequests, viewer: viewer, weekStart: weekStart, calendar: calendar)
        stats.isPartial = hasMore
        return stats
    }

    public func fetchDiff(repo: String, number: Int) async throws -> String {
        let token = try await requireToken()
        guard let path = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(path)/pulls/\(number)")
        else { throw DashboardError.http(400) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            // 406: GitHub refuses to render diffs past its size limit.
            throw status == 401 ? DashboardError.unauthorized : DashboardError.http(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func publish(_ finding: Finding, repo: String, number: Int, commitSha: String) async throws -> URL {
        let token = try await requireToken()
        guard let path = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DashboardError.http(400)
        }
        let base = "https://api.github.com/repos/\(path)"

        // Most specific first: the line range, then the single line, then a plain comment on the pull request.
        var attempts: [(String, [String: Any])] = []
        if finding.anchored != false, !commitSha.isEmpty {
            let line: [String: Any] = ["body": finding.comment, "commit_id": commitSha, "path": finding.path,
                                       "side": "RIGHT", "line": finding.line]
            if let end = finding.endLine, end > finding.line {
                let range = line.merging(["start_line": finding.line, "start_side": "RIGHT", "line": end]) { $1 }
                attempts.append(("\(base)/pulls/\(number)/comments", range))
            }
            attempts.append(("\(base)/pulls/\(number)/comments", line))
        }
        attempts.append(("\(base)/issues/\(number)/comments",
                         ["body": "`\(finding.path):\(finding.line)`\n\n\(finding.comment)"]))

        var lastStatus = 0
        for (address, body) in attempts {
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("bearer \(token.value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await transport.send(request)
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch lastStatus {
            case 201:
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let link = (object?["html_url"] as? String).flatMap(URL.init(string:)),
                      link.scheme == "https", link.host == "github.com"
                else { throw DashboardError.graphQL("the comment was created but GitHub returned no link") }
                return link
            case 422:
                // GitHub cannot attach a comment to that line; try the next, less specific place.
                continue
            case 401: throw DashboardError.unauthorized
            case 403, 404: throw DashboardError.cannotWrite
            default: throw DashboardError.http(lastStatus)
            }
        }
        throw DashboardError.http(lastStatus)
    }

    private func requireToken() async throws -> Token {
        guard let token = await tokens.token() else { throw DashboardError.missingToken }
        return token
    }

    private static func scope(_ orgs: [String]) -> String {
        orgs.map { " org:\($0)" }.joined()
    }

    private func post<Payload: Decodable>(_ query: String, token: Token, variables: [String: Any]) async throws -> Payload {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        var (data, response) = try await transport.send(request)
        // GitHub answers 502 when a query runs out of time; a second attempt usually hits a warm cache.
        if let status = (response as? HTTPURLResponse)?.statusCode, (500...599).contains(status) {
            (data, response) = try await transport.send(request)
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw status == 401 ? DashboardError.unauthorized : DashboardError.http(status)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Response<Payload>.self, from: data)
        guard let payload = decoded.data else {
            throw DashboardError.graphQL(decoded.errors?.map(\.message).joined(separator: "; ") ?? "empty response")
        }
        return payload
    }
}

private struct Search<Node: Decodable>: Decodable {
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    let issueCount: Int
    let nodes: [Node?]
    let pageInfo: PageInfo?
}

private struct Viewer: Decodable {
    let login: String
    let organizations: Connection<Actor>?
}

private struct ListsPayload: Decodable {
    let viewer: Viewer
    let mine: Search<PullRequest>
    let reviews: Search<PullRequest>
}

private struct ReviewedPayload: Decodable {
    let reviewed: Search<PullRequest>
}

private struct StatsPayload: Decodable {
    let viewer: Actor
    let week: Search<WeekPullRequest>
}

private struct Response<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable { let message: String }

    let data: Payload?
    let errors: [GraphQLError]?
}

extension GitHubService {
    fileprivate static let listsQuery = """
    query($mine: String!, $reviews: String!) {
      viewer { login organizations(first: 100) { nodes { login } } }
      mine: search(query: $mine, type: ISSUE, first: 50) { issueCount nodes { ...PR } }
      reviews: search(query: $reviews, type: ISSUE, first: 50) { issueCount nodes { ...PR } }
    }
    """ + pullRequestFragment

    fileprivate static let reviewedQuery = """
    query($reviewed: String!) {
      reviewed: search(query: $reviewed, type: ISSUE, first: 30) { issueCount nodes { ...PR } }
    }
    """ + pullRequestFragment

    fileprivate static let pullRequestFragment = """

    fragment PR on PullRequest {
      id number title url isDraft updatedAt headRefOid additions deletions reviewDecision bodyText
      repository { nameWithOwner }
      author { __typename login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      timelineItems(last: 8, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT]) {
        nodes {
          __typename
          ... on IssueComment { author { __typename login } createdAt bodyText url }
          ... on PullRequestReview { author { __typename login } submittedAt state bodyText url }
          ... on PullRequestCommit { url commit { messageHeadline committedDate author { name user { login } } } }
        }
      }
    }
    """

    fileprivate static let statsQuery = """
    query($week: String!, $first: Int!, $after: String) {
      viewer { login }
      week: search(query: $week, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            repository { nameWithOwner }
            commits(last: 100) {
              nodes { commit { oid authoredDate additions deletions parents { totalCount } author { user { login } } } }
            }
          }
        }
      }
    }
    """
}
