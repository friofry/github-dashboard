import Foundation
import Observation

public protocol PullRequestDiffSource: Sendable {
    func fetchDiff(repo: String, number: Int) async throws -> String
}

public protocol ReviewPreferences: AnyObject {
    var autoReview: Bool { get set }
    var makeLessons: Bool { get set }
    var claudeModel: String { get set }
    var maxRunBudget: Double { get set }
    /// Automatic runs stop for the day once today's spending reaches this.
    var dailyAutoBudget: Double { get set }
    /// Language for explanations; empty means English. Comments for GitHub are always English.
    var reviewLanguage: String { get set }
    /// Review requests that already existed when auto-review was switched on; nil until the next sync records them.
    var reviewBaseline: [String]? { get set }
}

/// Runs Claude reviews one at a time, keeps their results, and decides which ones start by themselves.
@MainActor
@Observable
public final class ReviewCoordinator {
    public enum Phase: Equatable, Sendable { case queued, reviewing, teaching }

    public enum Status: Equatable, Sendable {
        case none
        case working(Phase)
        /// Reviewed at the pull request's current head commit.
        case current
        /// Reviewed, but the pull request has new commits since.
        case outdated
        case failed(String)
    }

    public private(set) var reviews: [String: Review] = [:]
    public private(set) var lessons: [String: URL] = [:]
    public private(set) var usage: [UsageEntry]

    public var autoReview: Bool {
        didSet {
            preferences.autoReview = autoReview
            preferences.reviewBaseline = nil
        }
    }
    public var makeLessons: Bool { didSet { preferences.makeLessons = makeLessons } }
    public var model: String { didSet { preferences.claudeModel = model } }
    public var maxRunBudget: Double { didSet { preferences.maxRunBudget = maxRunBudget } }
    public var dailyAutoBudget: Double { didSet { preferences.dailyAutoBudget = dailyAutoBudget } }
    public var language: String { didSet { preferences.reviewLanguage = language } }

    private var working: [String: Phase] = [:]
    private var failures: [String: String] = [:]
    /// "id@sha" of automatic attempts, so a failing review is not retried on every refresh.
    private var attempted: Set<String> = []
    /// Queued by the app rather than by the user; these respect the daily budget.
    private var automatic: Set<String> = []
    private var queue: [PullRequest] = []
    private var worker: Task<Void, Never>?
    private var reviewRequests: [PullRequest] = []

    private let source: PullRequestDiffSource
    private let engine: ReviewEngine
    private let skill: ReviewSkill
    private let workspace: ReviewWorkspace
    private let usageStore: UsageStore
    private let preferences: ReviewPreferences
    private let now: () -> Date

    public init(source: PullRequestDiffSource, engine: ReviewEngine, skill: ReviewSkill, workspace: ReviewWorkspace,
                usageStore: UsageStore, preferences: ReviewPreferences, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.engine = engine
        self.skill = skill
        self.workspace = workspace
        self.usageStore = usageStore
        self.preferences = preferences
        self.now = now
        usage = usageStore.load()
        autoReview = preferences.autoReview
        makeLessons = preferences.makeLessons
        model = preferences.claudeModel
        maxRunBudget = preferences.maxRunBudget
        dailyAutoBudget = preferences.dailyAutoBudget
        language = preferences.reviewLanguage
    }

    // MARK: State

    public func status(for pullRequest: PullRequest) -> Status {
        if let phase = working[pullRequest.id] { return .working(phase) }
        if let message = failures[pullRequest.id] { return .failed(message) }
        guard let review = reviews[pullRequest.id] else { return .none }
        guard let reviewed = review.pr?.headSha else { return .current }
        return reviewed == pullRequest.headRefOid ? .current : .outdated
    }

    /// Review requests that have no review of their current commit and are not being worked on.
    public var pending: [PullRequest] {
        reviewRequests.filter {
            switch status(for: $0) {
            case .none, .outdated, .failed: return true
            case .working, .current: return false
            }
        }
    }

    public var isWorking: Bool { !working.isEmpty }

    public var spentToday: Double {
        UsageTotals(usage, since: Calendar.current.startOfDay(for: now())).costUSD
    }

    public func link(for finding: Finding, in pullRequest: PullRequest) -> URL? {
        GitHubLinks.line(repo: pullRequest.repository.nameWithOwner, number: pullRequest.number,
                         headSha: reviews[pullRequest.id]?.pr?.headSha, finding: finding)
    }

    // MARK: Actions

    /// Call after every dashboard refresh: picks up reviews from disk and starts the automatic ones.
    public func sync(with dashboard: Dashboard) {
        reviewRequests = dashboard.reviews
        for pullRequest in dashboard.mine + dashboard.reviews {
            let repo = pullRequest.repository.nameWithOwner
            reviews[pullRequest.id] = workspace.loadReview(repo: repo, number: pullRequest.number)
            lessons[pullRequest.id] = workspace.latestLesson(repo: repo, number: pullRequest.number)
        }
        guard autoReview else { return }

        // Switching auto-review on must not review the whole backlog: only what arrives or changes afterwards.
        guard let baseline = preferences.reviewBaseline.map(Set.init) else {
            preferences.reviewBaseline = dashboard.reviews.map(\.id)
            return
        }
        for pullRequest in dashboard.reviews {
            let isNew: Bool
            switch status(for: pullRequest) {
            case .none: isNew = !baseline.contains(pullRequest.id)
            case .outdated: isNew = true
            case .working, .current, .failed: isNew = false
            }
            if isNew, attempted.insert("\(pullRequest.id)@\(pullRequest.headRefOid)").inserted {
                automatic.insert(pullRequest.id)
                request(pullRequest)
            }
        }
    }

    public func request(_ pullRequest: PullRequest) {
        guard working[pullRequest.id] == nil else { return }
        failures[pullRequest.id] = nil
        working[pullRequest.id] = .queued
        queue.append(pullRequest)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                await self.run(self.queue.removeFirst())
            }
            self?.worker = nil
        }
    }

    public func requestAllPending() {
        pending.forEach(request)
    }

    /// Waits until the queue is empty. For tests and for callers that need the result.
    public func waitUntilIdle() async {
        await worker?.value
    }

    private func run(_ pullRequest: PullRequest) async {
        let repo = pullRequest.repository.nameWithOwner
        let options = RunOptions(model: model, maxBudgetUSD: maxRunBudget)
        var kind = UsageEntry.Kind.review
        defer { working[pullRequest.id] = nil }
        // Many requests can arrive at once; past the daily budget they wait for a manual "Review".
        if automatic.remove(pullRequest.id) != nil, spentToday >= dailyAutoBudget { return }
        do {
            working[pullRequest.id] = .reviewing
            let diff = DiffAnnotator.annotate(try await source.fetchDiff(repo: repo, number: pullRequest.number))
            try workspace.writeInputs(pullRequest: pullRequest, diff: diff)

            let input = ReviewInput.make(pullRequest: pullRequest, language: language, diff: diff)
            var (review, spent) = try await engine.review(input: input, schema: try skill.schema(), options: options)
            record(spent, for: pullRequest, kind: .review, succeeded: true)

            for index in review.findings.indices {
                let finding = review.findings[index]
                review.findings[index].anchored = diff.contains(path: finding.path, line: finding.line)
            }
            review.pr = .init(repo: repo, number: pullRequest.number, headSha: pullRequest.headRefOid, reviewedAt: now())
            try workspace.save(review, repo: repo, number: pullRequest.number)
            reviews[pullRequest.id] = review

            guard makeLessons else { return }
            kind = .lesson
            working[pullRequest.id] = .teaching
            let prompt = try skill.lessonPrompt(repo: repo, number: pullRequest.number, title: pullRequest.title)
            let directory = workspace.directory(repo: repo, number: pullRequest.number)
            record(try await engine.lesson(in: directory, prompt: prompt, options: options), for: pullRequest,
                   kind: .lesson, succeeded: true)
            lessons[pullRequest.id] = workspace.latestLesson(repo: repo, number: pullRequest.number)
        } catch {
            if let spent = (error as? ClaudeError)?.usage {
                record(spent, for: pullRequest, kind: kind, succeeded: false)
            }
            // A failed lesson does not take the finished review away.
            if kind == .review || reviews[pullRequest.id] == nil {
                failures[pullRequest.id] = error.localizedDescription
            }
        }
    }

    private func record(_ spent: ClaudeUsage, for pullRequest: PullRequest, kind: UsageEntry.Kind, succeeded: Bool) {
        let entry = UsageEntry(date: now(), repo: pullRequest.repository.nameWithOwner, number: pullRequest.number,
                               kind: kind, usage: spent, succeeded: succeeded)
        usageStore.append(entry)
        usage.append(entry)
    }
}
