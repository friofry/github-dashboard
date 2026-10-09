import Foundation
import Observation

/// Which failed Jenkins checks to start again. Pure: it only decides.
public enum AutoRestartPolicy {
    /// What was already done for one check on one commit.
    public struct Attempt: Codable, Equatable, Sendable {
        public var count: Int
        /// The failed build that was restarted last; while the check still points at it, the restart is on its way.
        public var lastBuild: URL
        /// True once the restarted run's result was counted; nil in data saved before results were counted.
        public var settled: Bool?
        /// When Jenkins was last asked; nil in data saved before the time was kept.
        public var date: Date?

        public init(count: Int, lastBuild: URL, settled: Bool? = nil, date: Date? = nil) {
            self.count = count
            self.lastBuild = lastBuild
            self.settled = settled
            self.date = date
        }
    }

    /// Something auto-restart did, or learned, about one check of one pull request.
    public struct Event: Codable, Identifiable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Jenkins accepted the restart.
            case requested
            /// Jenkins did not accept it; `detail` says why.
            case refused
            case passed
            case failedAgain
            /// Failed again with no automatic restarts left.
            case gaveUp
        }

        public var id = UUID()
        public let date: Date
        /// The pull request's id.
        public let pullRequest: String
        public let check: String
        public let kind: Kind
        /// Automatic restarts made on the commit by then.
        public let count: Int
        public var detail: String?
    }

    /// How restarts of one job ended, over every pull request.
    public struct Outcome: Codable, Equatable, Sendable {
        public var passed = 0
        public var failedAgain = 0

        public init(passed: Int = 0, failedAgain: Int = 0) {
            self.passed = passed
            self.failedAgain = failedAgain
        }

        public var total: Int { passed + failedAgain }
    }

    /// One Jenkins job as it stands now on my pull requests.
    public struct Job: Identifiable, Equatable, Sendable {
        public let name: String
        public let failing: Int
        public let running: Int
        public let passing: Int

        public var id: String { name }
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
    ///   - off: check names that are never restarted.
    ///   - attempts: keyed by `key(_:check:)`.
    ///   - limit: restarts per check per commit, so a real failure does not loop forever.
    public static func decide(pullRequests: [PullRequest], isEnabled: (PullRequest) -> Bool, server: URL,
                              off: Set<String> = [], attempts: [String: Attempt], limit: Int) -> [Restart] {
        pullRequests.filter(isEnabled).flatMap { pullRequest in
            pullRequest.checks.compactMap { check -> Restart? in
                guard check.state == .failure, !off.contains(check.name),
                      let url = check.url, let build = build(for: check, server: server)
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

    /// The Jenkins build behind a check; nil when it is not one, or lives on another server than `server`.
    public static func build(for check: CheckContext, server: URL?) -> JenkinsBuild? {
        guard let url = check.url, let build = JenkinsBuild(url: url) else { return nil }
        if let server, !build.isOn(server) { return nil }
        return build
    }

    /// Every Jenkins job seen on the pull requests: failing first, then running, then by name.
    public static func jobs(pullRequests: [PullRequest], server: URL?) -> [Job] {
        var counts: [String: (failing: Int, running: Int, passing: Int)] = [:]
        for check in pullRequests.flatMap(\.checks) where build(for: check, server: server) != nil {
            var count = counts[check.name] ?? (0, 0, 0)
            switch check.state {
            case .failure: count.failing += 1
            case .pending: count.running += 1
            case .success: count.passing += 1
            case nil: break
            }
            counts[check.name] = count
        }
        return counts.map { Job(name: $0.key, failing: $0.value.failing, running: $0.value.running, passing: $0.value.passing) }
            .sorted { ($1.failing, $1.running, $0.name) < ($0.failing, $0.running, $1.name) }
    }
}

public protocol RestartPreferences: AnyObject {
    /// Every one of my pull requests, not only the ones switched on one by one.
    var autoRestartAll: Bool { get set }
    var autoRestartPullRequests: [String] { get set }
    /// Pull requests left out while every pull request is switched on.
    var autoRestartPausedPullRequests: [String] { get set }
    /// Check names that are never restarted.
    var autoRestartOffChecks: [String] { get set }
    /// Keyed by check name.
    var restartOutcomes: [String: AutoRestartPolicy.Outcome] { get set }
    /// Newest first.
    var restartHistory: [AutoRestartPolicy.Event] { get set }
    var jenkinsServer: String { get set }
    var jenkinsUser: String { get set }
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

    /// Narrows My PRs to the pull requests whose CI needs a look.
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case failed, running, restarted, gaveUp

        public var id: String { rawValue }
    }

    /// One check of a pull request, with what auto-restart did about it.
    public struct Line: Identifiable, Equatable, Sendable {
        public enum Status: Sendable { case failed, restarting, gaveUp, running, passed, unknown }

        public let check: CheckContext
        public let status: Status
        /// Restarts already made on this commit.
        public let restarts: Int
        /// A failed Jenkins build on the configured server that was not asked to start again yet.
        public let canRestart: Bool
        /// When Jenkins was asked to start it again, while that restart is on its way.
        public let asked: Date?
        /// The job is switched off, so it is only ever restarted by hand.
        public let autoOff: Bool

        public var id: String { check.name }
    }

    static let logSize = 20
    static let historySize = 200

    public var restartAll: Bool { didSet { preferences.autoRestartAll = restartAll } }
    public var server: String { didSet { preferences.jenkinsServer = server } }
    public var user: String { didSet { preferences.jenkinsUser = user } }
    public var limit: Int { didSet { preferences.autoRestartLimit = limit } }
    public private(set) var hasToken = false
    /// Why the last restart did not happen; cleared by the next one that does.
    public private(set) var lastError: String?
    /// Recent restarts, newest first.
    public private(set) var log: [Entry] = []

    /// How restarts of each job ended, by check name.
    public private(set) var outcomes: [String: AutoRestartPolicy.Outcome] { didSet { preferences.restartOutcomes = outcomes } }

    private var history: [AutoRestartPolicy.Event] { didSet { preferences.restartHistory = history } }
    private var enabled: Set<String> { didSet { preferences.autoRestartPullRequests = enabled.sorted() } }
    private var paused: Set<String> { didSet { preferences.autoRestartPausedPullRequests = paused.sorted() } }
    private var offChecks: Set<String> { didSet { preferences.autoRestartOffChecks = offChecks.sorted() } }
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
        limit = max(1, preferences.autoRestartLimit)
        outcomes = preferences.restartOutcomes
        history = preferences.restartHistory
        enabled = Set(preferences.autoRestartPullRequests)
        paused = Set(preferences.autoRestartPausedPullRequests)
        offChecks = Set(preferences.autoRestartOffChecks)
        attempts = preferences.restartAttempts
    }

    public func isEnabled(_ pullRequest: PullRequest) -> Bool {
        restartAll ? !paused.contains(pullRequest.id) : enabled.contains(pullRequest.id)
    }

    /// With every pull request switched on, switching one off only pauses that one.
    public func setEnabled(_ pullRequest: PullRequest, _ on: Bool) {
        if restartAll {
            if on { paused.remove(pullRequest.id) } else { paused.insert(pullRequest.id) }
        } else {
            if on { enabled.insert(pullRequest.id) } else { enabled.remove(pullRequest.id) }
        }
    }

    public func isCheckEnabled(_ name: String) -> Bool { !offChecks.contains(name) }

    public func setCheckEnabled(_ name: String, _ on: Bool) {
        if on { offChecks.remove(name) } else { offChecks.insert(name) }
    }

    /// The Jenkins jobs of my pull requests; before a server is entered, every check that links to a Jenkins build.
    public func jobs(in pullRequests: [PullRequest]) -> [AutoRestartPolicy.Job] {
        AutoRestartPolicy.jobs(pullRequests: pullRequests, server: serverURL)
    }

    /// The pull request's checks: failed first, then running, then the rest.
    public func lines(for pullRequest: PullRequest) -> [Line] {
        pullRequest.checks.map { check in
            let attempt = attempts[AutoRestartPolicy.key(pullRequest, check: check.name)]
            let restartable = serverURL.map { AutoRestartPolicy.build(for: check, server: $0) != nil } ?? false
            // A request Jenkins refused is settled at once, and may be made again by hand.
            let asked = attempt != nil && attempt?.lastBuild == check.url && attempt?.settled != true
            let status: Line.Status
            switch check.state {
            case .failure: status = asked ? .restarting : (attempt?.count ?? 0) >= limit ? .gaveUp : .failed
            case .pending: status = .running
            case .success: status = .passed
            case nil: status = .unknown
            }
            return Line(check: check, status: status, restarts: attempt?.count ?? 0,
                        canRestart: check.state == .failure && restartable && !asked,
                        asked: asked ? attempt?.date : nil, autoOff: restartable && offChecks.contains(check.name))
        }
        .sorted { (Self.rank($0.status), $0.check.name) < (Self.rank($1.status), $1.check.name) }
    }

    private static func rank(_ status: Line.Status) -> Int {
        switch status {
        case .failed, .gaveUp: return 0
        case .restarting: return 1
        case .running: return 2
        case .unknown: return 3
        case .passed: return 4
        }
    }

    /// What happened to the pull request's checks, newest first.
    public func history(for pullRequest: PullRequest) -> [AutoRestartPolicy.Event] {
        history.filter { $0.pullRequest == pullRequest.id }
    }

    public func matches(_ pullRequest: PullRequest, _ filter: Filter) -> Bool {
        switch filter {
        // Data saved before checks were listed only has the overall state.
        case .failed: return pullRequest.checks.isEmpty ? pullRequest.ci == .failure
            : pullRequest.checks.contains { $0.state == .failure }
        case .running: return pullRequest.checks.isEmpty ? pullRequest.ci == .pending
            : pullRequest.checks.contains { $0.state == .pending }
        case .restarted: return restarts(for: pullRequest) > 0
        case .gaveUp: return lines(for: pullRequest).contains { $0.status == .gaveUp }
        }
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
        settle(mine)
        // Only commits still on screen matter; older counts would only grow the stored map.
        let current = Set(mine.map { "\($0.id)@\($0.headRefOid)|" })
        let pruned = attempts.filter { entry in current.contains { entry.key.hasPrefix($0) } }
        if pruned.count != attempts.count { attempts = pruned }

        guard mine.contains(where: isEnabled) else {
            lastError = nil
            return
        }
        guard let credentials = await credentials() else {
            lastError = "Auto-restart is on, but the Jenkins address, user or API token is missing in Settings."
            return
        }
        let restarts = AutoRestartPolicy.decide(pullRequests: mine, isEnabled: isEnabled, server: credentials.server,
                                                off: offChecks, attempts: attempts, limit: limit)
        for restart in restarts {
            guard await perform(restart, in: mine, credentials: credentials, counted: true) else { return }
        }
    }

    /// Starts one failed check again because the user asked; it does not use up the automatic restarts.
    public func restartNow(_ pullRequest: PullRequest, check name: String) async {
        await restartNow(in: [pullRequest]) { $0.check.name == name }
    }

    /// Starts every failed Jenkins check of the pull requests again, whether or not auto-restart is on for them.
    public func restartAllFailed(in pullRequests: [PullRequest]) async {
        await restartNow(in: pullRequests) { _ in true }
    }

    /// How many checks `restartAllFailed` would start.
    public func restartable(in pullRequests: [PullRequest]) -> Int {
        pullRequests.map { lines(for: $0).filter(\.canRestart).count }.reduce(0, +)
    }

    private func restartNow(in pullRequests: [PullRequest], where wanted: (Line) -> Bool) async {
        guard let credentials = await credentials() else {
            lastError = "Enter the Jenkins address, user and API token in Settings to restart jobs."
            return
        }
        for pullRequest in pullRequests {
            for line in lines(for: pullRequest) where line.canRestart && wanted(line) {
                guard let url = line.check.url,
                      let build = AutoRestartPolicy.build(for: line.check, server: credentials.server) else { continue }
                let restart = AutoRestartPolicy.Restart(
                    key: AutoRestartPolicy.key(pullRequest, check: line.check.name), pullRequest: pullRequest.id,
                    check: line.check.name, build: build, failedRun: url)
                guard await perform(restart, in: pullRequests, credentials: credentials, counted: false) else { return }
            }
        }
    }

    private func credentials() async -> JenkinsCredentials? {
        let login = user.trimmingCharacters(in: .whitespaces)
        guard let server = serverURL, !login.isEmpty, let token = await tokenStore.token()?.value else { return nil }
        return JenkinsCredentials(server: server, user: login, token: token)
    }

    /// False when asking Jenkins again is pointless.
    private func perform(_ restart: AutoRestartPolicy.Restart, in pullRequests: [PullRequest],
                         credentials: JenkinsCredentials, counted: Bool) async -> Bool {
        // Recorded before asking, so a Jenkins that keeps failing the request is not asked forever either.
        let count = (attempts[restart.key]?.count ?? 0) + (counted ? 1 : 0)
        attempts[restart.key] = AutoRestartPolicy.Attempt(count: count, lastBuild: restart.failedRun, settled: false,
                                                          date: now())
        let title = pullRequests.first { $0.id == restart.pullRequest }
            .map { "\($0.repository.nameWithOwner) #\($0.number)" } ?? restart.pullRequest
        do {
            try await client.restart(restart.build, credentials: credentials)
            record(Entry(date: now(), pullRequest: title, check: restart.check, error: nil))
            note(.requested, restart.pullRequest, restart.check, count: count)
            lastError = nil
        } catch {
            // Nothing was started, so there will be no result to count.
            attempts[restart.key]?.settled = true
            let message = error.localizedDescription
            record(Entry(date: now(), pullRequest: title, check: restart.check, error: message))
            note(.refused, restart.pullRequest, restart.check, count: count, detail: message)
            lastError = "Could not restart \(restart.check) on \(title): \(message)"
            // The same credentials will fail for every other job too.
            if let failure = error as? JenkinsError, failure == .unauthorized { return false }
        }
        return true
    }

    /// Counts how each restarted run ended, once GitHub shows its result.
    private func settle(_ mine: [PullRequest]) {
        for pullRequest in mine {
            for check in pullRequest.checks {
                let key = AutoRestartPolicy.key(pullRequest, check: check.name)
                guard let attempt = attempts[key], attempt.settled == false else { continue }
                var outcome = outcomes[check.name] ?? .init()
                if check.state == .success {
                    outcome.passed += 1
                    note(.passed, pullRequest.id, check.name, count: attempt.count)
                } else if check.state == .failure, check.url != attempt.lastBuild {
                    outcome.failedAgain += 1
                    let stopped = attempt.count >= limit || !isEnabled(pullRequest) || offChecks.contains(check.name)
                    note(stopped ? .gaveUp : .failedAgain, pullRequest.id, check.name, count: attempt.count)
                } else {
                    continue
                }
                outcomes[check.name] = outcome
                attempts[key]?.settled = true
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

    private func note(_ kind: AutoRestartPolicy.Event.Kind, _ pullRequest: String, _ check: String, count: Int,
                      detail: String? = nil) {
        history.insert(.init(date: now(), pullRequest: pullRequest, check: check, kind: kind, count: count,
                             detail: detail), at: 0)
        if history.count > Self.historySize { history.removeLast(history.count - Self.historySize) }
    }

    private func record(_ entry: Entry) {
        log.insert(entry, at: 0)
        if log.count > Self.logSize { log.removeLast(log.count - Self.logSize) }
    }
}
