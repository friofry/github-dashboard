import Foundation
import Observation

/// What a GitHub notification is about, as far as system notifications go.
public enum NotificationKind: String, CaseIterable, Codable, Sendable {
    /// Comments and reviews on my pull requests.
    case myPullRequests
    /// Replies in conversations I commented in.
    case replies
    /// Someone wrote my login or one of my teams.
    case mentions
    /// A review request or an assignment.
    case assignments

    /// GitHub's `reason`; reasons this app does not notify about (subscriptions, CI, security) give nil.
    public init?(reason: String) {
        switch reason {
        case "author": self = .myPullRequests
        case "comment": self = .replies
        case "mention", "team_mention": self = .mentions
        case "review_requested", "assign": self = .assignments
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .myPullRequests: return "Comments on my pull requests"
        case .replies: return "Replies to my comments"
        case .mentions: return "Mentions of me"
        case .assignments: return "Review requests and assignments"
        }
    }
}

/// One thread from GitHub's notifications inbox.
public struct GitHubNotification: Decodable, Sendable {
    public struct Subject: Decodable, Sendable {
        public let title: String
        /// The API address of the pull request or issue.
        public let url: URL?
        /// The API address of the newest comment; may equal `url` or be absent.
        public let latestCommentURL: URL?
        public let type: String

        private enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentURL = "latest_comment_url"
        }
    }

    public struct Repo: Decodable, Sendable {
        public let fullName: String

        private enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    public let id: String
    public let reason: String
    public let updatedAt: Date
    public let subject: Subject
    public let repository: Repo

    public init(id: String, reason: String, updatedAt: Date, subject: Subject, repository: Repo) {
        self.id = id
        self.reason = reason
        self.updatedAt = updatedAt
        self.subject = subject
        self.repository = repository
    }

    private enum CodingKeys: String, CodingKey {
        case id, reason, subject, repository
        case updatedAt = "updated_at"
    }

    public var kind: NotificationKind? { NotificationKind(reason: reason) }

    /// The pull request or issue on github.com, read from its API address.
    public var webURL: URL? {
        guard let url = subject.url, url.scheme == "https", url.host == "api.github.com" else { return nil }
        let parts = url.pathComponents
        guard parts.count == 6, parts[1] == "repos", Int(parts[5]) != nil else { return nil }
        let page: String
        switch parts[4] {
        case "pulls": page = "pull"
        case "issues": page = "issues"
        default: return nil
        }
        return URL(string: "https://github.com/\(parts[2])/\(parts[3])/\(page)/\(parts[5])")
    }

    /// "acme/api #7", or the repository alone when the subject has no number.
    public var place: String {
        guard let number = webURL?.lastPathComponent else { return repository.fullName }
        return "\(repository.fullName) #\(number)"
    }
}

/// The newest comment of a thread, as the REST API returns it.
public struct NotificationComment: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public let login: String
        public let type: String?
    }

    public let user: User?
    public let body: String?
    public let htmlURL: URL?

    public init(user: User?, body: String?, htmlURL: URL?) {
        self.user = user
        self.body = body
        self.htmlURL = htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case user, body
        case htmlURL = "html_url"
    }
}

public protocol NotificationSource: Sendable {
    /// Unread notifications updated after `since`.
    func fetchNotifications(since: Date) async throws -> [GitHubNotification]
    func fetchComment(_ url: URL) async throws -> NotificationComment
}

/// What is shown in the system notification.
public struct NotificationAlert: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let body: String
    /// Opened when the notification is clicked; always on github.com.
    public let url: URL
}

/// Shows alerts in the system's notification center.
@MainActor
public protocol NotificationPosting: AnyObject {
    /// Asks once; later calls return the user's choice without asking again.
    func requestPermission() async -> Bool
    func post(_ alert: NotificationAlert) async throws
}

/// Which notifications are worth an alert. Pure: it only decides.
public enum NotificationPolicy {
    /// Oldest first, so alerts arrive in the order things happened.
    public static func pending(_ notifications: [GitHubNotification], kinds: Set<NotificationKind>, since: Date,
                               delivered: [String: Date]) -> [GitHubNotification] {
        notifications
            .filter { notification in
                guard let kind = notification.kind, kinds.contains(kind) else { return false }
                return notification.updatedAt > since
                    && notification.updatedAt > (delivered[notification.id] ?? .distantPast)
            }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public static func headline(_ notification: GitHubNotification) -> String {
        switch notification.reason {
        case "author": return "New comment on your pull request"
        case "comment": return "New reply"
        case "mention": return "You were mentioned"
        case "team_mention": return "Your team was mentioned"
        case "review_requested": return "Review requested"
        case "assign": return "Assigned to you"
        default: return "New activity"
        }
    }

    /// Nil when the newest comment is my own or a bot's: nothing to be told about.
    public static func alert(for notification: GitHubNotification, comment: NotificationComment?,
                             viewer: String) -> NotificationAlert? {
        if let user = comment?.user,
           user.login.caseInsensitiveCompare(viewer) == .orderedSame || user.type == "Bot" {
            return nil
        }
        let page = comment?.htmlURL.flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
            ?? notification.webURL
            ?? URL(string: "https://github.com/notifications")!
        var body = notification.subject.title
        if let comment, let login = comment.user?.login {
            let text = (comment.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            body = text.isEmpty ? "\(login) commented" : "\(login): \(text.prefix(Self.bodyLength))"
        }
        return NotificationAlert(
            id: "\(notification.id)@\(Int(notification.updatedAt.timeIntervalSince1970))",
            title: "\(headline(notification)) · \(notification.place)",
            subtitle: notification.subject.title,
            body: body,
            url: page
        )
    }

    static let bodyLength = 240
}

public protocol NotificationPreferences: AnyObject {
    /// Kinds switched on; nil means all of them.
    var notificationKinds: [String]? { get set }
    /// Nothing older than this is ever shown; set on the first check so a fresh install does not flood.
    var notificationsSince: Date? { get set }
    /// Thread id -> the update already shown for it.
    var deliveredNotifications: [String: Date] { get set }
}

/// Posts system notifications for new comments, replies, mentions and review requests.
@MainActor
@Observable
public final class Notifier {
    /// How far back each check looks; older updates were either shown already or are stale news.
    static let window: TimeInterval = 86_400
    /// Delivered marks older than this are no longer needed to avoid repeats.
    static let retention: TimeInterval = 7 * 86_400
    /// Alerts per check; the rest are summed up in one, so a long absence does not bury the screen.
    static let maxAlerts = 5

    public private(set) var kinds: Set<NotificationKind> {
        didSet { preferences.notificationKinds = kinds.map(\.rawValue).sorted() }
    }
    /// Why notifications could not be checked or shown; cleared by the next check that works.
    public private(set) var lastError: String?

    private var delivered: [String: Date] { didSet { preferences.deliveredNotifications = delivered } }
    private var running = false
    private var loop: Task<Void, Never>?
    private let source: NotificationSource
    private let poster: NotificationPosting
    private let preferences: NotificationPreferences
    private let now: () -> Date

    public init(source: NotificationSource, poster: NotificationPosting, preferences: NotificationPreferences,
                now: @escaping () -> Date = Date.init) {
        self.source = source
        self.poster = poster
        self.preferences = preferences
        self.now = now
        kinds = preferences.notificationKinds.map { Set($0.compactMap(NotificationKind.init(rawValue:))) }
            ?? Set(NotificationKind.allCases)
        delivered = preferences.deliveredNotifications
    }

    public func isEnabled(_ kind: NotificationKind) -> Bool { kinds.contains(kind) }

    public func setEnabled(_ kind: NotificationKind, _ on: Bool) {
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
    }

    /// Checks GitHub every `interval` once the viewer is known.
    public func start(every interval: Duration = .seconds(60), viewer: @escaping @MainActor () -> String?) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let viewer = viewer() { await self?.sync(viewer: viewer) }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func sync(viewer: String) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let date = now()
        guard let since = preferences.notificationsSince, !kinds.isEmpty else {
            // First check, or everything switched off: start counting from now, so nothing old pops up later.
            preferences.notificationsSince = date
            lastError = nil
            return
        }
        guard await poster.requestPermission() else {
            preferences.notificationsSince = date
            lastError = "Notifications are turned off for GitHub Dashboard in System Settings → Notifications."
            return
        }
        do {
            let notifications = try await source.fetchNotifications(since: max(since, date.addingTimeInterval(-Self.window)))
            let pending = NotificationPolicy.pending(notifications, kinds: kinds, since: since, delivered: delivered)
            for notification in pending { delivered[notification.id] = notification.updatedAt }
            let cutoff = date.addingTimeInterval(-Self.retention)
            delivered = delivered.filter { $0.value > cutoff }

            let shown = pending.suffix(Self.maxAlerts)
            for notification in shown {
                guard let alert = await alert(for: notification, viewer: viewer) else { continue }
                try await poster.post(alert)
            }
            if pending.count > shown.count {
                let more = pending.count - shown.count
                try await poster.post(NotificationAlert(
                    id: "more@\(Int(date.timeIntervalSince1970))",
                    title: "\(more) more update\(more == 1 ? "" : "s") on GitHub",
                    subtitle: "",
                    body: "Open your GitHub notifications to see them all.",
                    url: URL(string: "https://github.com/notifications")!
                ))
            }
            lastError = nil
        } catch DashboardError.http(let status) where status == 403 || status == 404 {
            lastError = """
            This token cannot read GitHub notifications. Sign in with the GitHub CLI, or use a classic token \
            with the notifications scope.
            """
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func alert(for notification: GitHubNotification, viewer: String) async -> NotificationAlert? {
        var comment: NotificationComment?
        // A review request points at the pull request itself, which says nothing new.
        if let url = notification.subject.latestCommentURL, url != notification.subject.url {
            comment = try? await source.fetchComment(url)
        }
        return NotificationPolicy.alert(for: notification, comment: comment, viewer: viewer)
    }
}
