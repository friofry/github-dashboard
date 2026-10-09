import DashboardCore
import XCTest

private let server = URL(string: "https://ci.acme.dev")!

/// My pull request with one check per (name, state, link).
private func pullRequest(id: String = "PR_1", sha: String = "sha-1",
                         checks: [(String, String, String)]) throws -> PullRequest {
    let contexts = checks.map { name, state, url in
        #"{ "__typename": "StatusContext", "context": "\#(name)", "state": "\#(state)", "targetUrl": "\#(url)" }"#
    }.joined(separator: ",")
    let json = """
    { "id": "\(id)", "number": 7, "title": "Add cache", "url": "https://github.com/acme/api/pull/7",
      "isDraft": false, "updatedAt": "2026-10-08T10:00:00Z", "headRefOid": "\(sha)", "additions": 1, "deletions": 1,
      "reviewDecision": null, "repository": { "nameWithOwner": "acme/api" },
      "author": { "__typename": "User", "login": "me" },
      "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "FAILURE",
                   "contexts": { "nodes": [\(contexts)] } } } }] },
      "timelineItems": { "nodes": [] } }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PullRequest.self, from: Data(json.utf8))
}

private let linuxRun3 = "https://ci.acme.dev/job/api/job/prs/job/linux/job/PR-7/3/display/redirect"
private let linuxRun4 = "https://ci.acme.dev/job/api/job/prs/job/linux/job/PR-7/4/display/redirect"

final class JenkinsBuildTests: XCTestCase {
    func testReadsTheClassicLink() throws {
        let build = try XCTUnwrap(JenkinsBuild(url: URL(string: linuxRun3)!))
        XCTAssertEqual(build.job.absoluteString, "https://ci.acme.dev/job/api/job/prs/job/linux/job/PR-7/")
        XCTAssertEqual(build.number, 3)
    }

    func testReadsTheBlueOceanLink() throws {
        let url = URL(string: "https://ci.status.im/blue/organizations/jenkins/status-go%2Fprs%2Flinux%2Fx86_64%2Fmain/detail/PR-7897/8/pipeline/")!
        let build = try XCTUnwrap(JenkinsBuild(url: url))
        XCTAssertEqual(build.job.absoluteString,
                       "https://ci.status.im/job/status-go/job/prs/job/linux/job/x86_64/job/main/job/PR-7897/")
        XCTAssertEqual(build.number, 8)
    }

    func testRefusesLinksThatAreNotABuild() {
        XCTAssertNil(JenkinsBuild(url: URL(string: "https://ci.acme.dev/job/api/job/PR-7/")!))
        XCTAssertNil(JenkinsBuild(url: URL(string: "https://github.com/acme/api/runs/1")!))
        XCTAssertNil(JenkinsBuild(url: URL(string: "https://ci.acme.dev/job/../3/")!))
    }

    func testKnowsWhichServerItIsOn() throws {
        let build = try XCTUnwrap(JenkinsBuild(url: URL(string: linuxRun3)!))
        XCTAssertTrue(build.isOn(server))
        XCTAssertTrue(build.isOn(URL(string: "https://CI.acme.dev/")!))
        XCTAssertFalse(build.isOn(URL(string: "https://ci.evil.dev")!))
        XCTAssertFalse(build.isOn(URL(string: "http://ci.acme.dev")!))
        XCTAssertFalse(build.isOn(URL(string: "https://ci.acme.dev/jenkins")!))
    }
}

final class CheckDecodingTests: XCTestCase {
    func testStatusesAndCheckRunsDecode() async throws {
        let transport = FakeTransport()
        let dashboard = try await GitHubService(tokens: StaticTokenProvider("t"), transport: transport)
            .fetchPullRequests(orgs: [], now: fixtureNow)
        let checks = try XCTUnwrap(dashboard.mine.first?.checks)

        XCTAssertEqual(checks.map(\.name), ["jenkins/prs/linux", "lint"])
        XCTAssertEqual(checks.map(\.state), [.failure, .pending])
        XCTAssertEqual(checks.first?.url?.host, "ci.acme.dev")
        XCTAssertEqual(dashboard.reviews.first?.checks.count, 0)
    }
}

final class AutoRestartPolicyTests: XCTestCase {
    private func decide(_ pullRequests: [PullRequest], checks: [String] = [],
                        attempts: [String: AutoRestartPolicy.Attempt] = [:], enabled: Bool = true,
                        limit: Int = 2) -> [AutoRestartPolicy.Restart] {
        AutoRestartPolicy.decide(pullRequests: pullRequests, isEnabled: { _ in enabled }, server: server,
                                 checks: checks, attempts: attempts, limit: limit)
    }

    func testRestartsOnlyFailedChecksOnTheJenkinsServer() throws {
        let pr = try pullRequest(checks: [
            ("jenkins/linux", "FAILURE", linuxRun3),
            ("jenkins/mac", "SUCCESS", "https://ci.acme.dev/job/api/job/mac/job/PR-7/2/"),
            ("jenkins/win", "PENDING", "https://ci.acme.dev/job/api/job/win/job/PR-7/2/"),
            ("elsewhere", "FAILURE", "https://ci.evil.dev/job/api/job/PR-7/2/"),
            ("actions", "ERROR", "https://github.com/acme/api/actions/runs/1"),
        ])
        let restarts = decide([pr])
        XCTAssertEqual(restarts.map(\.check), ["jenkins/linux"])
        XCTAssertEqual(restarts.first?.build.number, 3)
        XCTAssertEqual(restarts.first?.key, "PR_1@sha-1|jenkins/linux")
    }

    func testNothingWhenSwitchedOff() throws {
        XCTAssertTrue(decide([try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun3)])], enabled: false).isEmpty)
    }

    func testChecksFilterMatchesPrefixes() throws {
        let pr = try pullRequest(checks: [
            ("jenkins/prs/linux/x86_64/main", "FAILURE", linuxRun3),
            ("jenkins/prs/package/status-app", "FAILURE", "https://ci.acme.dev/job/api/job/package/job/PR-7/5/"),
        ])
        XCTAssertEqual(decide([pr], checks: ["jenkins/prs/linux"]).map(\.check), ["jenkins/prs/linux/x86_64/main"])
    }

    func testTheSameFailedRunIsRestartedOnce() throws {
        let pr = try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun3)])
        let asked = ["PR_1@sha-1|jenkins/linux": AutoRestartPolicy.Attempt(count: 1, lastBuild: URL(string: linuxRun3)!)]
        XCTAssertTrue(decide([pr], attempts: asked).isEmpty, "the restart is on its way; GitHub still shows the old run")

        let failedAgain = try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun4)])
        XCTAssertEqual(decide([failedAgain], attempts: asked).map(\.build.number), [4])
    }

    func testStopsAtTheLimitUntilANewCommit() throws {
        let attempts = ["PR_1@sha-1|jenkins/linux": AutoRestartPolicy.Attempt(count: 2, lastBuild: URL(string: linuxRun3)!)]
        let failedAgain = try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun4)])
        XCTAssertTrue(decide([failedAgain], attempts: attempts).isEmpty)

        let newCommit = try pullRequest(sha: "sha-2", checks: [("jenkins/linux", "FAILURE", linuxRun4)])
        XCTAssertEqual(decide([newCommit], attempts: attempts).count, 1)
    }
}

private final class FakeJenkins: JenkinsRestarting, @unchecked Sendable {
    var error: Error?
    private(set) var restarted: [JenkinsBuild] = []

    func restart(_ build: JenkinsBuild, credentials: JenkinsCredentials) async throws {
        restarted.append(build)
        if let error { throw error }
    }
}

@MainActor
final class AutoRestarterTests: XCTestCase {
    private let jenkins = FakeJenkins()
    private let preferences = InMemoryPreferences()

    private func restarter(token: String? = "api-token") -> AutoRestarter {
        preferences.jenkinsServer = "https://ci.acme.dev"
        preferences.jenkinsUser = "me"
        return AutoRestarter(client: jenkins, tokenStore: FakeTokenStore(token), preferences: preferences)
    }

    func testRestartsOnlyPullRequestsSwitchedOnAndRemembersIt() async throws {
        let on = try pullRequest(id: "PR_1", checks: [("jenkins/linux", "FAILURE", linuxRun3)])
        let off = try pullRequest(id: "PR_2", checks: [("jenkins/linux", "FAILURE", linuxRun3)])
        let restarter = restarter()
        restarter.setEnabled(on, true)

        await restarter.sync(mine: [on, off])
        await restarter.sync(mine: [on, off])

        XCTAssertEqual(jenkins.restarted.map(\.number), [3])
        XCTAssertEqual(restarter.restarts(for: on), 1)
        XCTAssertEqual(restarter.restarts(for: off), 0)
        XCTAssertEqual(preferences.autoRestartPullRequests, ["PR_1"])
        XCTAssertEqual(preferences.restartAttempts["PR_1@sha-1|jenkins/linux"]?.count, 1)
        XCTAssertEqual(restarter.log.first?.check, "jenkins/linux")
        XCTAssertNil(restarter.lastError)
    }

    func testAllMyPullRequests() async throws {
        let restarter = restarter()
        restarter.restartAll = true
        await restarter.sync(mine: [try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun3)])])
        XCTAssertEqual(jenkins.restarted.count, 1)
        XCTAssertTrue(preferences.autoRestartAll)
    }

    func testMissingTokenIsReportedAndNothingRuns() async throws {
        let restarter = restarter(token: nil)
        restarter.restartAll = true
        await restarter.sync(mine: [try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun3)])])
        XCTAssertTrue(jenkins.restarted.isEmpty)
        XCTAssertNotNil(restarter.lastError)
    }

    func testAFailedRequestStillCountsTowardsTheLimit() async throws {
        jenkins.error = JenkinsError.forbidden
        let restarter = restarter()
        restarter.restartAll = true
        let pr = try pullRequest(checks: [("jenkins/linux", "FAILURE", linuxRun3)])
        await restarter.sync(mine: [pr])
        await restarter.sync(mine: [pr])

        XCTAssertEqual(jenkins.restarted.count, 1)
        XCTAssertEqual(restarter.restarts(for: pr), 1)
        XCTAssertNotNil(restarter.log.first?.error)
        XCTAssertNotNil(restarter.lastError)
    }

    func testCountsForOldCommitsAreDropped() async throws {
        preferences.restartAttempts = ["PR_1@old|jenkins/linux": .init(count: 2, lastBuild: URL(string: linuxRun3)!)]
        await restarter().sync(mine: [try pullRequest(checks: [])])
        XCTAssertTrue(preferences.restartAttempts.isEmpty)
    }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    var statuses: [Int]
    private(set) var requests: [URLRequest] = []

    init(_ statuses: [Int]) { self.statuses = statuses }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = statuses.isEmpty ? 201 : statuses.removeFirst()
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class JenkinsClientTests: XCTestCase {
    private let credentials = JenkinsCredentials(server: server, user: "me", token: "secret")
    private let build = JenkinsBuild(url: URL(string: linuxRun3)!)!

    func testStartsAParameterizedJobWithItsDefaults() async throws {
        let transport = RecordingTransport([201])
        try await JenkinsClient(transport: transport).restart(build, credentials: credentials)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://ci.acme.dev/job/api/job/prs/job/linux/job/PR-7/buildWithParameters")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic \(Data("me:secret".utf8).base64EncodedString())")
    }

    func testFallsBackToBuildForAJobWithoutParameters() async throws {
        let transport = RecordingTransport([500, 201])
        try await JenkinsClient(transport: transport).restart(build, credentials: credentials)
        XCTAssertEqual(transport.requests.last?.url?.lastPathComponent, "build")
    }

    func testRejectedCredentialsStopAtOnce() async {
        let transport = RecordingTransport([401])
        do {
            try await JenkinsClient(transport: transport).restart(build, credentials: credentials)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? JenkinsError, .unauthorized)
            XCTAssertEqual(transport.requests.count, 1)
        }
    }
}
