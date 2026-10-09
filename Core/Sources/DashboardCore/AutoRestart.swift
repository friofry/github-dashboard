import Foundation
import Observation

/// Which failed Jenkins checks to start again. Pure: it only decides.
public enum AutoRestartPolicy {
    /// What was already done for one check on one commit.
    public struct Attempt: Codable, Equatable, Sendable {
        public var count: Int
        /// The failed build that was restarted last; while the check still points at it, the restart is on its way.
        public var lastBuild: URL

        public init(count: Int, lastBuild: URL) {
            self.count = count
            self.lastBuild = lastBuild
        }
    }

    public struct Restart: Equatable, Sendable {
        public let key: String
        public let pullRequest: String
        public let check: String
        public let build: JenkinsBuild
        /// The failed run itself, remembered so the same failure is not restarted twice.
        public let failedRun: URL
    }

    /// - Parameters:
    ///   - checks: names or name prefixes to restart; empty means every Jenkins check.
    ///   - attempts: keyed by `key(_:check:)`.
    ///   - limit: restarts per check per commit, so a real failure does not loop forever.
    public static func decide(pullRequests: [PullRequest], isEnabled: (PullRequest) -> Bool, server: URL,
                              checks: [String], attempts: [String: Attempt], limit: Int) -> [Restart] {
        pullRequests.filter(isEnabled).flatMap { pullRequest in
            pullRequest.checks.compactMap { check -> Restart? in
                guard check.state == .failure, matches(check.name, checks),
                      let url = check.url, let build = JenkinsBuild(url: url), build.isOn(server)
                else { return nil }
                let key = Self.key(pullRequest, check: check.name)
                if let attempt = attempts[key], attempt.count >= limit || attempt.lastBuild == url { return nil }
                return Restart(key: key, pullRequest: pullRequest.id, check: check.name, build: build, failedRun: url)
            }
        }
    }

    /// A new commit starts the count again.
    public static func key(_ pullRequest: PullRequest, check: String) -> String {
        "\(pullRequest.id)@\(pullRequest.headRefOid)|\(check)"
    }

    static func matches(_ name: String, _ checks: [String]) -> Bool {
        checks.isEmpty || checks.contains { name.hasPrefix($0) }
    }
}

public protocol RestartPreferences: AnyObject {
    /// Every one of my pull requests, not only the ones switched on one by one.
    var autoRestartAll: Bool { get set }
    var autoRestartPullRequests: [String] { get set }
    var jenkinsServer: String { get set }
    var jenkinsUser: String { get set }
    /// Comma separated check names or prefixes; empty means every Jenkins check.
    var autoRestartChecks: String { get set }
    var autoRestartLimit: Int { get set }
    var restartAttempts: [String: AutoRestartPolicy.Attempt] { get set }
}

/// Starts failed Jenkins jobs of my pull requests again, up to a limit per commit.
@MainActor
@Observable
public final class AutoRestarter {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let pullRequest: String
        public let check: String
        /// Nil when Jenkins accepted the restart.
        public let error: String?
    }

    static let logSize = 20

    public var restartAll: Bool { didSet { preferences.autoRestartAll = restartAll } }
    public var server: String { didSet { preferences.jenkinsServer = server } }
    public var user: String { didSet { preferences.jenkinsUser = user } }
    public var checks: String { didSet { preferences.autoRestartChecks = checks } }
    public var limit: Int { didSet { preferences.autoRestartLimit = limit } }
    public private(set) var hasToken = false
    /// Why the last restart did not happen; cleared by the next one that does.
    public private(set) var lastError: String?
    /// Recent restarts, newest first.
    public private(set) var log: [Entry] = []

    private var enabled: Set<String> { didSet { preferences.autoRestartPullRequests = enabled.sorted() } }
    private var attempts: [String: AutoRestartPolicy.Attempt] { didSet { preferences.restartAttempts = attempts } }
    private var running = false
    private let client: JenkinsRestarting
    private let tokenStore: TokenStore
    private let preferences: RestartPreferences
    private let now: () -> Date

    public init(client: JenkinsRestarting, tokenStore: TokenStore, preferences: RestartPreferences,
                now: @escaping () -> Date = Date.init) {
        self.client = client
        self.tokenStore = tokenStore
        self.preferences = preferences
        self.now = now
        restartAll = preferences.autoRestartAll
        server = preferences.jenkinsServer
        user = preferences.jenkinsUser
        checks = preferences.autoRestartChecks
        limit = max(1, preferences.autoRestartLimit)
        enabled = Set(preferences.autoRestartPullRequests)
        attempts = preferences.restartAttempts
    }

    public func isEnabled(_ pullRequest: PullRequest) -> Bool {
        restartAll || enabled.contains(pullRequest.id)
    }

    public func setEnabled(_ pullRequest: PullRequest, _ on: Bool) {
        if on { enabled.insert(pullRequest.id) } else { enabled.remove(pullRequest.id) }
    }

    /// Restarts already made on the pull request's head commit, over all its checks.
    public func restarts(for pullRequest: PullRequest) -> Int {
        let prefix = "\(pullRequest.id)@\(pullRequest.headRefOid)|"
        return attempts.filter { $0.key.hasPrefix(prefix) }.values.map(\.count).reduce(0, +)
    }

    /// The server as typed, if it is a usable https address.
    public var serverURL: URL? {
        let text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Call after each load of my pull requests.
    public func sync(mine: [PullRequest]) async {
        guard !running else { return }
        running = true
        defer { running = false }

        hasToken = await tokenStore.token() != nil
        // Only commits still on screen matter; older counts would only grow the stored map.
        let current = Set(mine.map { "\($0.id)@\($0.headRefOid)|" })
        let pruned = attempts.filter { entry in current.contains { entry.key.hasPrefix($0) } }
        if pruned.count != attempts.count { attempts = pruned }

        guard mine.contains(where: isEnabled) else {
            lastError = nil
            return
        }
        let login = user.trimmingCharacters(in: .whitespaces)
        guard let server = serverURL, !login.isEmpty, let token = await tokenStore.token()?.value else {
            lastError = "Auto-restart is on, but the Jenkins address, user or API token is missing in Settings."
            return
        }
        let names = DashboardStore.list(checks)
        let restarts = AutoRestartPolicy.decide(pullRequests: mine, isEnabled: isEnabled, server: server,
                                                checks: names, attempts: attempts, limit: limit)
        let credentials = JenkinsCredentials(server: server, user: login, token: token)
        for restart in restarts {
            // Counted before asking, so a Jenkins that keeps failing the request is not asked forever either.
            let count = (attempts[restart.key]?.count ?? 0) + 1
            attempts[restart.key] = AutoRestartPolicy.Attempt(count: count, lastBuild: restart.failedRun)
            let title = mine.first { $0.id == restart.pullRequest }.map { "\($0.repository.nameWithOwner) #\($0.number)" }
                ?? restart.pullRequest
            do {
                try await client.restart(restart.build, credentials: credentials)
                record(Entry(date: now(), pullRequest: title, check: restart.check, error: nil))
                lastError = nil
            } catch {
                let message = error.localizedDescription
                record(Entry(date: now(), pullRequest: title, check: restart.check, error: message))
                lastError = "Could not restart \(restart.check) on \(title): \(message)"
                // The same credentials will fail for every other job too.
                if let failure = error as? JenkinsError, failure == .unauthorized { return }
            }
        }
    }

    // MARK: Token

    public func saveToken(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try tokenStore.save(trimmed)
            hasToken = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func removeToken() {
        do {
            try tokenStore.delete()
            hasToken = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func checkToken() async {
        hasToken = await tokenStore.token() != nil
    }

    private func record(_ entry: Entry) {
        log.insert(entry, at: 0)
        if log.count > Self.logSize { log.removeLast(log.count - Self.logSize) }
    }
}
