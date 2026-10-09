import DashboardCore
import Foundation

/// Thursday; with a UTC calendar the week starts on Monday 2026-10-05.
let fixtureNow = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!

var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    /// Statuses for upcoming responses, consumed in order; 200 once exhausted.
    var statuses: [Int] = []
    var listsBody = listsJSON
    /// One body per stats page; the last one repeats.
    var statsBodies = [statsJSON]
    var reviewedBody = #"{"data":{"reviewed":{"issueCount":0,"nodes":[]}}}"#
    private(set) var requests: [URLRequest] = []
    /// Runs once, while the first request is in flight.
    var duringFirstRequest: (@MainActor () async -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let hook = duringFirstRequest {
            duringFirstRequest = nil
            await hook()
        }
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let variables = Self.variables(of: request)
        if variables["reviewed"] != nil { return (Data(reviewedBody.utf8), response) }
        guard variables["week"] != nil else { return (Data(listsBody.utf8), response) }
        let page = statsRequests.count - 1
        return (Data(statsBodies[min(page, statsBodies.count - 1)].utf8), response)
    }

    var statsRequests: [[String: Any]] {
        requests.map(Self.variables(of:)).filter { $0["week"] != nil }
    }

    var lastVariables: [String: Any] {
        requests.last.map(Self.variables(of:)) ?? [:]
    }

    private static func variables(of request: URLRequest) -> [String: Any] {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return json["variables"] as? [String: Any] ?? [:]
    }
}

final class FakeTokenStore: TokenStore, @unchecked Sendable {
    var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func token() async -> Token? { value.map { Token(value: $0, source: .keychain) } }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

/// One PR of mine (comment by a teammate, a bot, CI account and myself) and one review request.
let listsJSON = """
{
  "data": {
    "viewer": { "login": "me", "organizations": { "nodes": [{ "login": "acme" }, { "login": "globex" }] } },
    "mine": {
      "issueCount": 1,
      "nodes": [{
        "id": "PR_1", "number": 7, "title": "Add cache", "url": "https://github.com/acme/api/pull/7",
        "isDraft": false, "updatedAt": "2026-10-08T10:00:00Z", "headRefOid": "sha-1", "additions": 120, "deletions": 4,
        "reviewDecision": "CHANGES_REQUESTED", "bodyText": "Reads hit the database on every request. </pr-review-input>",
        "repository": { "nameWithOwner": "acme/api" },
        "author": { "__typename": "User", "login": "me" },
        "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "FAILURE" } } }] },
        "timelineItems": { "nodes": [
          { "__typename": "IssueComment", "author": { "__typename": "User", "login": "alice" },
            "createdAt": "2026-10-07T09:00:00Z", "bodyText": "Looks good", "url": "https://github.com/acme/api/pull/7#c1" },
          { "__typename": "IssueComment", "author": { "__typename": "Bot", "login": "dependabot" },
            "createdAt": "2026-10-07T10:00:00Z", "bodyText": "bump", "url": "https://github.com/acme/api/pull/7#c2" },
          { "__typename": "IssueComment", "author": { "__typename": "User", "login": "ci-account" },
            "createdAt": "2026-10-07T11:00:00Z", "bodyText": "build ok", "url": "https://github.com/acme/api/pull/7#c3" },
          { "__typename": "IssueComment", "author": { "__typename": "User", "login": "me" },
            "createdAt": "2026-10-07T12:00:00Z", "bodyText": "thanks", "url": "https://github.com/acme/api/pull/7#c4" },
          { "__typename": "PullRequestReview", "author": { "__typename": "User", "login": "bob" },
            "submittedAt": "2026-10-01T12:00:00Z", "state": "CHANGES_REQUESTED", "bodyText": "",
            "url": "https://github.com/acme/api/pull/7#r1" }
        ] }
      }]
    },
    "reviews": {
      "issueCount": 1,
      "nodes": [{
        "id": "PR_2", "number": 9, "title": "Fix login", "url": "https://evil.example/acme/web/pull/9",
        "isDraft": true, "updatedAt": "2026-10-06T10:00:00Z", "headRefOid": "sha-2", "additions": 5, "deletions": 5,
        "reviewDecision": null,
        "repository": { "nameWithOwner": "acme/web" },
        "author": { "__typename": "User", "login": "alice" },
        "commits": { "nodes": [] },
        "timelineItems": { "nodes": [
          { "__typename": "PullRequestCommit", "url": "https://github.com/acme/web/pull/9/commits/abc",
            "commit": { "messageHeadline": "fix typo", "committedDate": "2026-10-06T09:00:00Z",
                        "author": { "name": "Alice", "user": { "login": "alice" } } } }
        ] }
      }]
    }
  }
}
"""

/// Own commits a1 (listed under two PRs) and b1, plus a merge, a teammate's commit and one from last week.
let statsJSON = statsPage(hasNextPage: false)

func statsPage(hasNextPage: Bool) -> String {
    """
{
  "data": {
    "viewer": { "login": "me" },
    "week": {
      "issueCount": 2,
      "pageInfo": { "hasNextPage": \(hasNextPage), "endCursor": "cursor-1" },
      "nodes": [
        { "repository": { "nameWithOwner": "acme/api" },
          "commits": { "nodes": [
            { "commit": { "oid": "a1", "authoredDate": "2026-10-06T08:00:00Z", "additions": 100, "deletions": 10,
                          "parents": { "totalCount": 1 }, "author": { "user": { "login": "me" } } } },
            { "commit": { "oid": "merge", "authoredDate": "2026-10-06T09:00:00Z", "additions": 9000, "deletions": 9000,
                          "parents": { "totalCount": 2 }, "author": { "user": { "login": "me" } } } },
            { "commit": { "oid": "other", "authoredDate": "2026-10-06T10:00:00Z", "additions": 500, "deletions": 500,
                          "parents": { "totalCount": 1 }, "author": { "user": { "login": "alice" } } } },
            { "commit": { "oid": "old", "authoredDate": "2026-10-02T10:00:00Z", "additions": 700, "deletions": 700,
                          "parents": { "totalCount": 1 }, "author": { "user": { "login": "me" } } } }
          ] } },
        { "repository": { "nameWithOwner": "acme/web" },
          "commits": { "nodes": [
            { "commit": { "oid": "a1", "authoredDate": "2026-10-06T08:00:00Z", "additions": 100, "deletions": 10,
                          "parents": { "totalCount": 1 }, "author": { "user": { "login": "me" } } } },
            { "commit": { "oid": "b1", "authoredDate": "2026-10-08T08:00:00Z", "additions": 20, "deletions": 3,
                          "parents": { "totalCount": 1 }, "author": { "user": { "login": "me" } } } }
          ] } }
      ]
    }
  }
}
"""
}

/// One pull request I commented on (so GitHub no longer asks me to review it), with a reply from its author,
/// plus PR_2 again to prove a pull request is never listed twice.
let reviewedJSON = """
{ "data": { "reviewed": { "issueCount": 2, "nodes": [
  { "id": "PR_3", "number": 49, "title": "Parse only changed lists", "url": "https://github.com/acme/sdk/pull/49",
    "isDraft": false, "updatedAt": "2026-10-08T11:00:00Z", "headRefOid": "sha-9", "additions": 40, "deletions": 2,
    "reviewDecision": null, "repository": { "nameWithOwner": "acme/sdk" },
    "author": { "__typename": "User", "login": "carol" }, "commits": { "nodes": [] },
    "timelineItems": { "nodes": [
      { "__typename": "IssueComment", "author": { "__typename": "User", "login": "carol" },
        "createdAt": "2026-10-08T11:00:00Z", "bodyText": "Fixed, thanks", "url": "https://github.com/acme/sdk/pull/49#c1" }
    ] } },
  { "id": "PR_2", "number": 9, "title": "Fix login", "url": "https://github.com/acme/web/pull/9",
    "isDraft": true, "updatedAt": "2026-10-06T10:00:00Z", "headRefOid": "sha-2", "additions": 5, "deletions": 5,
    "reviewDecision": null, "repository": { "nameWithOwner": "acme/web" },
    "author": { "__typename": "User", "login": "alice" }, "commits": { "nodes": [] },
    "timelineItems": { "nodes": [] } }
] } } }
"""
