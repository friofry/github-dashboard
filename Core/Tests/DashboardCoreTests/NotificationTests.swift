@testable import DashboardCore
import XCTest

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func notification(id: String = "1", reason: String = "author", updated: String = "2026-10-08T11:00:00Z",
                          comment: String? = "https://api.github.com/repos/acme/api/issues/comments/5") -> GitHubNotification {
    GitHubNotification(
        id: id, reason: reason, updatedAt: date(updated),
        subject: .init(title: "Add cache", url: URL(string: "https://api.github.com/repos/acme/api/pulls/7"),
                       latestCommentURL: comment.flatMap(URL.init(string:)), type: "PullRequest"),
        repository: .init(fullName: "acme/api")
    )
}

private func comment(by login: String, type: String = "User", body: String = "Please rename this") -> NotificationComment {
    NotificationComment(user: .init(login: login, type: type), body: body,
                        htmlURL: URL(string: "https://github.com/acme/api/pull/7#issuecomment-5"))
}

private final class FakeSource: NotificationSource, @unchecked Sendable {
    var notifications: [GitHubNotification] = []
    var comments: [URL: NotificationComment] = [:]
    var error: Error?
    private(set) var sinces: [Date] = []

    func fetchNotifications(since: Date) async throws -> [GitHubNotification] {
        sinces.append(since)
        if let error { throw error }
        return notifications
    }

    func fetchComment(_ url: URL) async throws -> NotificationComment {
        guard let comment = comments[url] else { throw DashboardError.http(404) }
        return comment
    }
}

@MainActor
private final class FakePoster: NotificationPosting {
    var allowed = true
    private(set) var posted: [NotificationAlert] = []

    func requestPermission() async -> Bool { allowed }
    func post(_ alert: NotificationAlert) async throws { posted.append(alert) }
}

final class NotificationModelTests: XCTestCase {
    func testReasonsMapToKinds() {
        XCTAssertEqual(NotificationKind(reason: "author"), .myPullRequests)
        XCTAssertEqual(NotificationKind(reason: "comment"), .replies)
        XCTAssertEqual(NotificationKind(reason: "team_mention"), .mentions)
        XCTAssertEqual(NotificationKind(reason: "review_requested"), .assignments)
        XCTAssertEqual(NotificationKind(reason: "assign"), .assignments)
        XCTAssertNil(NotificationKind(reason: "subscribed"))
        XCTAssertNil(NotificationKind(reason: "ci_activity"))
    }

    func testWebAddressComesFromTheAPIAddress() {
        XCTAssertEqual(notification().webURL?.absoluteString, "https://github.com/acme/api/pull/7")
        XCTAssertEqual(notification().place, "acme/api #7")
        let foreign = GitHubNotification(
            id: "2", reason: "mention", updatedAt: .now,
            subject: .init(title: "x", url: URL(string: "https://evil.example/repos/acme/api/pulls/7"),
                           latestCommentURL: nil, type: "PullRequest"),
            repository: .init(fullName: "acme/api"))
        XCTAssertNil(foreign.webURL)
    }

    func testDecodesTheRESTAnswer() throws {
        let json = """
        [{ "id": "42", "reason": "review_requested", "updated_at": "2026-10-08T11:00:00Z",
           "subject": { "title": "Fix login", "url": "https://api.github.com/repos/acme/web/pulls/9",
                        "latest_comment_url": null, "type": "PullRequest" },
           "repository": { "full_name": "acme/web" } }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([GitHubNotification].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.kind, .assignments)
        XCTAssertEqual(decoded.first?.webURL?.absoluteString, "https://github.com/acme/web/pull/9")
    }

    func testAlertSkipsMyOwnCommentsAndBots() {
        XCTAssertNil(NotificationPolicy.alert(for: notification(), comment: comment(by: "Me"), viewer: "me"))
        XCTAssertNil(NotificationPolicy.alert(for: notification(), comment: comment(by: "ci", type: "Bot"), viewer: "me"))
        let alert = NotificationPolicy.alert(for: notification(), comment: comment(by: "alice"), viewer: "me")
        XCTAssertEqual(alert?.title, "New comment on your pull request · acme/api #7")
        XCTAssertEqual(alert?.body, "alice: Please rename this")
        XCTAssertEqual(alert?.url.absoluteString, "https://github.com/acme/api/pull/7#issuecomment-5")
    }

    func testAlertNeverLinksOutsideGitHub() {
        let evil = NotificationComment(user: .init(login: "alice", type: "User"), body: "hi",
                                       htmlURL: URL(string: "https://evil.example/x"))
        let alert = NotificationPolicy.alert(for: notification(), comment: evil, viewer: "me")
        XCTAssertEqual(alert?.url.absoluteString, "https://github.com/acme/api/pull/7")
    }

    func testPendingKeepsEnabledNewUpdatesOldestFirst() {
        let since = date("2026-10-08T10:00:00Z")
        let list = [
            notification(id: "late", updated: "2026-10-08T12:00:00Z"),
            notification(id: "early", reason: "mention", updated: "2026-10-08T11:00:00Z"),
            notification(id: "old", updated: "2026-10-08T09:00:00Z"),
            notification(id: "shown", updated: "2026-10-08T11:30:00Z"),
            notification(id: "off", reason: "review_requested", updated: "2026-10-08T11:00:00Z"),
            notification(id: "ci", reason: "ci_activity", updated: "2026-10-08T11:00:00Z"),
        ]
        let pending = NotificationPolicy.pending(
            list, kinds: [.myPullRequests, .mentions], since: since,
            delivered: ["shown": date("2026-10-08T11:30:00Z")])
        XCTAssertEqual(pending.map(\.id), ["early", "late"])
    }
}

private let clock = date("2026-10-08T12:00:00Z")

@MainActor
final class NotifierTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let source = FakeSource()
        let poster = FakePoster()
        let preferences = InMemoryPreferences()

        init(since: String? = "2026-10-08T10:00:00Z") {
            preferences.notificationsSince = since.map(date)
        }

        func notifier() -> Notifier {
            Notifier(source: source, poster: poster, preferences: preferences, now: { clock })
        }
    }

    func testFirstCheckOnlyRemembersTheTime() async {
        let fixture = Fixture(since: nil)
        fixture.source.notifications = [notification(updated: "2026-10-08T11:00:00Z")]
        await fixture.notifier().sync(viewer: "me")
        XCTAssertTrue(fixture.poster.posted.isEmpty)
        XCTAssertTrue(fixture.source.sinces.isEmpty)
        XCTAssertEqual(fixture.preferences.notificationsSince, clock)
    }

    func testPostsEachNewUpdateOnce() async throws {
        let fixture = Fixture()
        let update = notification()
        fixture.source.notifications = [update]
        fixture.source.comments[try XCTUnwrap(update.subject.latestCommentURL)] = comment(by: "alice")
        let notifier = fixture.notifier()

        await notifier.sync(viewer: "me")
        await notifier.sync(viewer: "me")

        XCTAssertEqual(fixture.poster.posted.map(\.body), ["alice: Please rename this"])
        XCTAssertNil(notifier.lastError)
        XCTAssertNotNil(fixture.preferences.deliveredNotifications["1"])
    }

    func testReviewRequestNeedsNoComment() async {
        let fixture = Fixture()
        fixture.source.notifications = [
            notification(reason: "review_requested", comment: "https://api.github.com/repos/acme/api/pulls/7"),
        ]
        await fixture.notifier().sync(viewer: "me")
        XCTAssertEqual(fixture.poster.posted.first?.title, "Review requested · acme/api #7")
        XCTAssertEqual(fixture.poster.posted.first?.body, "Add cache")
    }

    func testSwitchedOffKindsStaySilent() async {
        let fixture = Fixture()
        fixture.source.notifications = [notification(reason: "mention", comment: nil)]
        let notifier = fixture.notifier()
        notifier.setEnabled(.mentions, false)
        await notifier.sync(viewer: "me")
        XCTAssertTrue(fixture.poster.posted.isEmpty)
        XCTAssertEqual(fixture.preferences.notificationKinds?.contains("mentions"), false)
    }

    func testLongAbsenceIsSummedUp() async {
        let fixture = Fixture(since: "2026-10-08T00:00:00Z")
        fixture.source.notifications = (0..<8).map {
            notification(id: "\($0)", reason: "mention", updated: "2026-10-08T0\($0 + 1):00:00Z", comment: nil)
        }
        await fixture.notifier().sync(viewer: "me")
        XCTAssertEqual(fixture.poster.posted.count, Notifier.maxAlerts + 1)
        XCTAssertEqual(fixture.poster.posted.last?.title, "3 more updates on GitHub")
    }

    func testLooksBackAtMostADay() async {
        let fixture = Fixture(since: "2026-09-01T00:00:00Z")
        await fixture.notifier().sync(viewer: "me")
        XCTAssertEqual(fixture.source.sinces, [date("2026-10-07T12:00:00Z")])
    }

    func testTokenWithoutNotificationsAccessIsExplained() async {
        let fixture = Fixture()
        fixture.source.error = DashboardError.http(403)
        let notifier = fixture.notifier()
        await notifier.sync(viewer: "me")
        XCTAssertEqual(notifier.lastError?.contains("notifications scope"), true)
    }

    func testDeniedPermissionMovesTheStartForward() async {
        let fixture = Fixture()
        fixture.poster.allowed = false
        let notifier = fixture.notifier()
        await notifier.sync(viewer: "me")
        XCTAssertNotNil(notifier.lastError)
        XCTAssertEqual(fixture.preferences.notificationsSince, clock)
        XCTAssertTrue(fixture.source.sinces.isEmpty)
    }
}
