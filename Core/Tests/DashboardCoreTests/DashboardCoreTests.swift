import DashboardCore
import XCTest

final class GitHubServiceTests: XCTestCase {
    private let transport = FakeTransport()

    private func service(token: String? = "t0ken") -> GitHubService {
        GitHubService(tokens: StaticTokenProvider(token), transport: transport, calendar: utcCalendar)
    }

    func testDecodesListsAndTotals() async throws {
        let dashboard = try await service().fetchPullRequests(orgs: [], now: fixtureNow)

        XCTAssertEqual(dashboard.viewer, "me")
        XCTAssertEqual(dashboard.organizations, ["acme", "globex"])
        XCTAssertEqual(dashboard.mineTotal, 1)
        XCTAssertEqual(dashboard.reviewsTotal, 1)
        XCTAssertEqual(dashboard.mine.first?.ci, .failure)
        XCTAssertEqual(dashboard.mine.first?.decision, .changesRequested)
        XCTAssertEqual(dashboard.mine.first?.events.count, 5)
        XCTAssertEqual(dashboard.reviews.first?.events.first?.kind, .commit)
    }

    func testWeeklyStatsCountOnlyOwnNonMergeCommitsOnce() async throws {
        let stats = try await service().fetchCodeStats(orgs: [], now: fixtureNow)

        // a1 (once, although it appears in two PRs) + b1; merge, other author and last week are skipped.
        XCTAssertEqual(stats.commits, 2)
        XCTAssertEqual(stats.additions, 120)
        XCTAssertEqual(stats.deletions, 13)
        XCTAssertEqual(stats.repos.map(\.repo), ["acme/api", "acme/web"])
        XCTAssertEqual(stats.days.map(\.additions), [0, 100, 0, 20, 0, 0, 0])
        XCTAssertFalse(stats.isPartial)
    }

    func testStatsFollowPagesWithTheCursor() async throws {
        transport.statsBodies = [statsPage(hasNextPage: true), statsPage(hasNextPage: false)]
        let stats = try await service().fetchCodeStats(orgs: [], now: fixtureNow)

        XCTAssertEqual(transport.statsRequests.count, 2)
        XCTAssertNil(transport.statsRequests[0]["after"])
        XCTAssertEqual(transport.statsRequests[1]["after"] as? String, "cursor-1")
        XCTAssertEqual(stats.commits, 2, "the same commits on a second page are not counted twice")
        XCTAssertFalse(stats.isPartial)
    }

    func testStatsStopAtThePageCapAndSaySo() async throws {
        transport.statsBodies = [statsPage(hasNextPage: true)]
        let stats = try await service().fetchCodeStats(orgs: [], now: fixtureNow)

        XCTAssertEqual(transport.statsRequests.count, 6)
        XCTAssertTrue(stats.isPartial)
    }

    func testSendsBearerTokenAndOrgScope() async throws {
        _ = try await service().fetchPullRequests(orgs: ["acme", "globex"], now: fixtureNow)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "bearer t0ken")
        XCTAssertTrue((transport.lastVariables["mine"] as? String)?.hasSuffix(" org:acme org:globex") == true)

        _ = try await service().fetchCodeStats(orgs: ["acme"], now: fixtureNow)
        let week = transport.lastVariables["week"] as? String
        XCTAssertTrue(week?.contains("updated:>=2026-10-04") == true)
        XCTAssertTrue(week?.hasSuffix(" org:acme") == true)
    }

    func testNoOrgsMeansNoScope() async throws {
        _ = try await service().fetchPullRequests(orgs: [], now: fixtureNow)
        XCTAssertFalse((transport.lastVariables["reviews"] as? String)?.contains("org:") == true)
    }

    func testMissingTokenFailsBeforeAnyRequest() async {
        do {
            _ = try await service(token: nil).fetchPullRequests(orgs: [], now: fixtureNow)
            XCTFail("expected missingToken")
        } catch {
            XCTAssertEqual(error as? DashboardError, .missingToken)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testServerErrorIsRetriedOnce() async throws {
        transport.statuses = [502]
        _ = try await service().fetchPullRequests(orgs: [], now: fixtureNow)
        XCTAssertEqual(transport.requests.count, 2)

        transport.statuses = [502, 502]
        do {
            _ = try await service().fetchPullRequests(orgs: [], now: fixtureNow)
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? DashboardError, .http(502))
        }
    }

    func testRejectedTokenAndGraphQLErrorsAreReported() async {
        transport.statuses = [401]
        do {
            _ = try await service().fetchPullRequests(orgs: [], now: fixtureNow)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DashboardError, .unauthorized)
        }

        transport.listsBody = #"{"errors":[{"message":"rate limited"}]}"#
        do {
            _ = try await service().fetchPullRequests(orgs: [], now: fixtureNow)
            XCTFail("expected graphQL error")
        } catch {
            XCTAssertEqual(error as? DashboardError, .graphQL("rate limited"))
        }
    }
}

final class TokenChainTests: XCTestCase {
    func testFirstAvailableProviderWins() async {
        let chain = TokenChain([
            StaticTokenProvider(nil, source: .keychain),
            StaticTokenProvider("", source: .keychain),
            StaticTokenProvider("env", source: .environment),
            StaticTokenProvider("cli", source: .ghCLI),
        ])
        let token = await chain.token()
        XCTAssertEqual(token?.value, "env")
        XCTAssertEqual(token?.source, .environment)
    }

    func testEmptyChainHasNoToken() async {
        let token = await TokenChain([]).token()
        XCTAssertNil(token)
    }
}

@MainActor
final class DashboardStoreTests: XCTestCase {
    private let transport = FakeTransport()
    private let preferences = InMemoryPreferences(ignoredLogins: "CI-Account")
    private let tokens = FakeTokenStore("t0ken")

    private func makeStore() -> DashboardStore {
        let service = GitHubService(tokens: tokens, transport: transport, calendar: utcCalendar)
        return DashboardStore(service: service, preferences: preferences, tokenStore: tokens, now: { fixtureNow })
    }

    func testFeedHidesOwnBotAndIgnoredActivity() async {
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.feed.map(\.actor), ["alice", "alice", "bob"])
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.hasStoredToken)
        XCTAssertEqual(store.stats?.additions, 120)
    }

    func testOnlyActivitySinceMondayIsNewUntilVisited() async throws {
        let store = makeStore()
        await store.refresh()
        let mine = try XCTUnwrap(store.dashboard?.mine.first)

        // bob's review is from last week.
        XCTAssertEqual(store.newCount(for: mine), 1)
        XCTAssertEqual(store.newTotal, 2)

        XCTAssertEqual(store.visit(mine), mine.url)
        XCTAssertEqual(store.newCount(for: mine), 0)
        XCTAssertEqual(preferences.seen["PR_1"], fixtureNow)

        store.markAllRead()
        XCTAssertEqual(store.newTotal, 0)
    }

    func testVisitRefusesLinksOutsideGitHub() async throws {
        let store = makeStore()
        await store.refresh()
        let foreign = try XCTUnwrap(store.dashboard?.reviews.first)

        XCTAssertNil(store.visit(foreign))
        XCTAssertNil(preferences.seen["PR_2"])
        XCTAssertNotNil(store.visit(foreign, at: foreign.events.first?.url))
    }

    func testUnreadPullRequestsSortFirst() async throws {
        let store = makeStore()
        await store.refresh()
        let dashboard = try XCTUnwrap(store.dashboard)
        _ = store.visit(dashboard.mine[0])

        XCTAssertEqual(store.sorted(dashboard.mine + dashboard.reviews).map(\.id), ["PR_2", "PR_1"])
    }

    func testScopeCheckboxesListViewerOrganizationsAndCustomOwners() async {
        preferences.orgs = "initech"
        let store = makeStore()
        XCTAssertEqual(store.availableOwners, ["initech"], "before the first load only saved owners are known")

        await store.refresh()
        XCTAssertEqual(store.availableOwners, ["me", "acme", "globex", "initech"])
        XCTAssertTrue(store.isSelected("Initech"))
        XCTAssertFalse(store.isSelected("me"))

        store.setOwner("me", selected: true)
        store.setOwner("ACME", selected: true)
        store.setOwner("initech", selected: false)
        XCTAssertEqual(preferences.orgs, "me, ACME")
        XCTAssertEqual(store.availableOwners, ["me", "acme", "globex"])

        await store.refresh()
        XCTAssertTrue((transport.lastVariables["week"] as? String)?.hasSuffix(" org:me org:ACME") == true)
    }

    func testScopeChangeDuringALoadIsNotLost() async {
        let store = makeStore()
        transport.duringFirstRequest = {
            store.setOwner("acme", selected: true)
            await store.refresh()
        }
        await store.refresh()

        XCTAssertTrue((transport.lastVariables["week"] as? String)?.hasSuffix(" org:acme") == true)
        XCTAssertEqual(transport.statsRequests.count, 1, "stats for the outdated scope are skipped")
        XCTAssertFalse(store.isLoading)
    }

    func testMissingTokenAsksForOneAndSavingRecovers() async {
        tokens.value = nil
        let store = makeStore()
        await store.refresh()

        XCTAssertTrue(store.needsToken)
        XCTAssertNil(store.dashboard)

        await store.saveToken("  fresh \n")
        XCTAssertEqual(tokens.value, "fresh")
        XCTAssertFalse(store.needsToken)
        XCTAssertNotNil(store.dashboard)
    }

    func testSettingsPersistAndOldReadMarksAreDropped() {
        preferences.seen = ["old": fixtureNow.addingTimeInterval(-100 * 86_400), "recent": fixtureNow]
        let store = makeStore()
        store.orgs = "acme"

        XCTAssertEqual(preferences.orgs, "acme")
        XCTAssertEqual(Array(preferences.seen.keys), ["recent"])
    }
}
