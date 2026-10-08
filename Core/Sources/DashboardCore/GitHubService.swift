import Foundation

public enum DashboardError: LocalizedError, Equatable {
    case missingToken
    case unauthorized
    case http(Int)
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "No GitHub token found. Add one in Settings."
        case .unauthorized: return "GitHub rejected the token. Check it in Settings."
        case .http(let code): return "GitHub API returned HTTP \(code)."
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
    /// - Parameter orgs: limits every list to these organizations; empty means all repositories.
    func fetchPullRequests(orgs: [String], now: Date) async throws -> Dashboard
    /// Slower than the lists on busy accounts, so it is loaded separately.
    func fetchCodeStats(orgs: [String], now: Date) async throws -> CodeStats
}

/// Talks to the GitHub GraphQL API. Lists and weekly stats are separate requests:
/// asked for together they exceed GitHub's 10 second budget on busy accounts.
public struct GitHubService: DashboardService {
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
            tokenSource: token.source,
            weekStart: CodeStats.weekStart(for: now, calendar: calendar),
            mine: payload.mine.nodes.compactMap { $0 },
            mineTotal: payload.mine.issueCount,
            reviews: payload.reviews.nodes.compactMap { $0 },
            reviewsTotal: payload.reviews.issueCount
        )
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

private struct ListsPayload: Decodable {
    let viewer: Actor
    let mine: Search<PullRequest>
    let reviews: Search<PullRequest>
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
      viewer { login }
      mine: search(query: $mine, type: ISSUE, first: 50) { issueCount nodes { ...PR } }
      reviews: search(query: $reviews, type: ISSUE, first: 50) { issueCount nodes { ...PR } }
    }
    fragment PR on PullRequest {
      id number title url isDraft updatedAt additions deletions reviewDecision
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
