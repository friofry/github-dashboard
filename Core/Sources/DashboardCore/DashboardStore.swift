import Foundation
import Observation

/// UI state: the last loaded dashboard plus what the user has already seen.
@MainActor
@Observable
public final class DashboardStore {
    /// Read marks older than this are dropped so the stored map cannot grow forever.
    static let seenRetention: TimeInterval = 90 * 86_400

    public private(set) var dashboard: Dashboard?
    /// Open pull requests the viewer has reviewed and is no longer asked to review.
    public private(set) var reviewed: [PullRequest] = []
    /// Nil until the first weekly stats request finishes.
    public private(set) var stats: CodeStats?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var needsToken = false
    public private(set) var lastRefresh: Date?
    public private(set) var hasStoredToken = false

    /// Comma or space separated repository owners (organizations or users); empty means all repositories.
    public var orgs: String { didSet { preferences.orgs = orgs } }
    public var ignoredLogins: String { didSet { preferences.ignoredLogins = ignoredLogins } }

    private var seen: [String: Date] { didSet { preferences.seen = seen } }
    private let service: DashboardService
    private let preferences: PreferencesStore
    private let tokenStore: TokenStore?
    private let now: () -> Date
    private var refreshLoop: Task<Void, Never>?
    private var refreshQueued = false
    /// Called after each successful load of the lists, e.g. to start reviews.
    public var onLoaded: ((Dashboard, [PullRequest]) -> Void)?
    private var loadedScope: [String]?

    public init(service: DashboardService, preferences: PreferencesStore, tokenStore: TokenStore? = nil,
                now: @escaping () -> Date = Date.init) {
        self.service = service
        self.preferences = preferences
        self.tokenStore = tokenStore
        self.now = now
        orgs = preferences.orgs
        ignoredLogins = preferences.ignoredLogins
        let cutoff = now().addingTimeInterval(-Self.seenRetention)
        seen = preferences.seen.filter { $0.value > cutoff }
        // Property observers do not run during init, so write the pruned map back by hand.
        preferences.seen = seen
    }

    public func startAutoRefresh(every interval: Duration = .seconds(300)) {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func refresh() async {
        // A request that arrives mid-load (say, after a scope change) must not be lost: run it right after.
        guard !isLoading else {
            refreshQueued = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshQueued = false
            await load()
        } while refreshQueued
    }

    private func load() async {
        hasStoredToken = await tokenStore?.token() != nil
        do {
            let scope = Self.list(orgs)
            if scope != loadedScope { stats = nil }
            dashboard = try await service.fetchPullRequests(orgs: scope, now: now())
            loadedScope = scope
            if let dashboard { onLoaded?(dashboard, reviewed) }
            lastRefresh = now()
            errorMessage = nil
            needsToken = false
            // Lists are on screen already; the rest follows, unless a newer request is waiting.
            guard !refreshQueued else { return }
            let listed = Set(allPullRequests.map(\.id))
            reviewed = try await service.fetchReviewed(orgs: scope).filter { !listed.contains($0.id) }
            if let dashboard { onLoaded?(dashboard, reviewed) }
            guard !refreshQueued else { return }
            stats = try await service.fetchCodeStats(orgs: scope, now: now())
        } catch {
            errorMessage = error.localizedDescription
            let failure = error as? DashboardError
            needsToken = failure == .missingToken || failure == .unauthorized
        }
    }

    // MARK: Scope

    /// Owners offered as checkboxes: the viewer, their organizations, then anything added by hand.
    public var availableOwners: [String] {
        var owners = dashboard.map { [$0.viewer] + $0.organizations } ?? []
        for owner in Self.list(orgs) where !owners.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) {
            owners.append(owner)
        }
        return owners
    }

    public func isSelected(_ owner: String) -> Bool {
        Self.list(orgs).contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    public func setOwner(_ owner: String, selected: Bool) {
        let name = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var owners = Self.list(orgs).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        if selected { owners.append(name) }
        orgs = owners.joined(separator: ", ")
    }

    // MARK: Token

    public func saveToken(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tokenStore else { return }
        do {
            try tokenStore.save(trimmed)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeToken() async {
        do {
            try tokenStore?.delete()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Updates

    /// Activity by other people, newest first.
    public func events(for pullRequest: PullRequest) -> [PREvent] {
        guard let dashboard else { return [] }
        let ignored = Set(Self.list(ignoredLogins).map { $0.lowercased() })
        return pullRequest.events
            .filter { $0.actor != dashboard.viewer && !$0.isBot && !ignored.contains($0.actor.lowercased()) }
            .sorted { $0.date > $1.date }
    }

    /// Until a PR is opened for the first time, everything since Monday counts as new.
    public func isNew(_ event: PREvent) -> Bool {
        event.date > (seen[event.pullRequest.id] ?? dashboard?.weekStart ?? .distantPast)
    }

    public func newCount(for pullRequest: PullRequest) -> Int {
        events(for: pullRequest).filter(isNew).count
    }

    public var feed: [PREvent] {
        followed.flatMap(events(for:)).sorted { $0.date > $1.date }
    }

    public var newTotal: Int { feed.filter(isNew).count }

    /// PRs with unread activity first, then most recently updated.
    public func sorted(_ pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.sorted {
            let lhs = newCount(for: $0) > 0, rhs = newCount(for: $1) > 0
            return lhs != rhs ? lhs : $0.updatedAt > $1.updatedAt
        }
    }

    /// Marks the PR read and returns the page to open, or nil if the link does not point at github.com.
    public func visit(_ pullRequest: PullRequest, at url: URL? = nil) -> URL? {
        let target = url ?? pullRequest.url
        guard target.scheme == "https", target.host == "github.com" else { return nil }
        seen[pullRequest.id] = now()
        return target
    }

    public func markAllRead() {
        let date = now()
        for pullRequest in followed { seen[pullRequest.id] = date }
    }

    private var allPullRequests: [PullRequest] { (dashboard?.mine ?? []) + (dashboard?.reviews ?? []) }

    /// Everything whose activity matters: replies in pull requests I reviewed count too.
    private var followed: [PullRequest] { allPullRequests + reviewed }

    static func list(_ text: String) -> [String] {
        // People paste "acme/" or "@acme"; only the name itself is a valid owner.
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/@")) }
            .filter { !$0.isEmpty }
    }
}
