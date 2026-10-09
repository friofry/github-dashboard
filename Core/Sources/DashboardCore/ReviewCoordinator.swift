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
    /// PR id -> when the user marked it done.
    var reviewDone: [String: Date] { get set }
    /// Pull requests asked for review that have not started yet, so the queue survives a restart.
    var reviewQueue: [String] { get set }
}

/// Runs Claude reviews one at a time and reports where each pull request stands.
/// What the reviews contain lives in `library`; posting comments lives in `publishing`.
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

    /// A run older than this with no result is taken for dead.
    static let abandonedAfter: TimeInterval = 30 * 60

    public let library: ReviewLibrary
    public let publishing: CommentPublishing
    public let doneMarks: DoneMarks
    public private(set) var usage: [UsageEntry]
    /// Automatic reviews that are waiting because today's spending reached the daily limit.
    public private(set) var heldByBudget: Set<String> = []

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
    /// Pull requests whose run was started by an earlier launch of the app and is still going.
    private var stillRunning: Set<String> = []
    private var attempted: Set<String> = []
    /// Queued by the app rather than by the user; these respect the daily budget.
    private var automatic: Set<String> = []
    /// Runs this process is waiting on, so recovery leaves them alone.
    private var active: Set<UUID> = []
    private var queue: [PullRequest] = []
    private var worker: Task<Void, Never>?
    private var reviewRequests: [PullRequest] = []

    private let source: PullRequestDiffSource
    private let engine: ReviewEngine
    private let skill: ReviewSkill
    private let journal: RunJournal
    private let usageStore: UsageStore
    private let preferences: ReviewPreferences
    private let now: () -> Date

    public init(source: PullRequestDiffSource, publisher: CommentPublisher? = nil, engine: ReviewEngine,
                skill: ReviewSkill, workspace: ReviewWorkspace, journal: RunJournal, usageStore: UsageStore,
                preferences: ReviewPreferences, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.engine = engine
        self.skill = skill
        self.journal = journal
        self.usageStore = usageStore
        self.preferences = preferences
        self.now = now
        let library = ReviewLibrary(workspace: workspace)
        self.library = library
        publishing = CommentPublishing(publisher: publisher, library: library)
        usage = usageStore.load()
        autoReview = preferences.autoReview
        makeLessons = preferences.makeLessons
        model = preferences.claudeModel
        maxRunBudget = preferences.maxRunBudget
        dailyAutoBudget = preferences.dailyAutoBudget
        language = preferences.reviewLanguage
        doneMarks = DoneMarks(preferences: preferences, now: now)
        recoverInterruptedRuns()
    }

    // MARK: State

    public func status(for pullRequest: PullRequest) -> Status {
        if let phase = working[pullRequest.id] { return .working(phase) }
        if stillRunning.contains(pullRequest.id) { return .working(.reviewing) }
        if let message = failures[pullRequest.id] { return .failed(message) }
        guard let review = library.reviews[pullRequest.id] else { return .none }
        guard let reviewed = review.pr?.headSha else { return .current }
        return reviewed == pullRequest.headRefOid ? .current : .outdated
    }

    /// Review requests that have no review of their current commit and are not being worked on.
    public var pending: [PullRequest] {
        reviewRequests.filter {
            guard !doneMarks.isDone($0) else { return false }
            switch status(for: $0) {
            case .none, .outdated, .failed: return true
            case .working, .current: return false
            }
        }
    }

    public var spentToday: Double {
        UsageTotals(usage, since: Calendar.current.startOfDay(for: now())).costUSD
    }

    /// Reviews of listed pull requests whose last run failed.
    public var failedCount: Int { failures.count }

    // MARK: Actions

    /// Call after every dashboard refresh: picks up results from disk and starts the automatic reviews.
    public func sync(with dashboard: Dashboard, reviewed: [PullRequest] = []) {
        recoverInterruptedRuns()
        reviewRequests = dashboard.reviews
        let everything = dashboard.mine + dashboard.reviews + reviewed
        let listed = Set(everything.map(\.id))
        failures = failures.filter { listed.contains($0.key) }
        library.load(everything)
        // Requests an earlier launch queued but never got to.
        for pullRequest in everything where preferences.reviewQueue.contains(pullRequest.id) { request(pullRequest) }
        guard autoReview else {
            heldByBudget = []
            return
        }

        let decision = AutoReviewPolicy.decide(requests: dashboard.reviews, reviewed: reviewed,
                                               baseline: preferences.reviewBaseline, attempted: attempted,
                                               status: status(for:))
        if preferences.reviewBaseline != decision.baseline { preferences.reviewBaseline = decision.baseline }
        // Past the daily limit nothing starts and nothing counts as attempted, so these run once the limit resets.
        guard spentToday < dailyAutoBudget else {
            heldByBudget = Set(decision.start)
            return
        }
        heldByBudget = []
        for pullRequest in everything where decision.start.contains(pullRequest.id) {
            attempted.insert(AutoReviewPolicy.attemptKey(pullRequest))
            automatic.insert(pullRequest.id)
            request(pullRequest)
        }
    }

    public func request(_ pullRequest: PullRequest) {
        guard working[pullRequest.id] == nil, !stillRunning.contains(pullRequest.id) else { return }
        failures[pullRequest.id] = nil
        heldByBudget.remove(pullRequest.id)
        working[pullRequest.id] = .queued
        queue.append(pullRequest)
        if !preferences.reviewQueue.contains(pullRequest.id) { preferences.reviewQueue.append(pullRequest.id) }
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

    /// Takes the results of runs that an earlier launch of the app started and did not live to see finish.
    /// A run that is paid for is never thrown away: its review is saved and its cost recorded.
    public func recoverInterruptedRuns() {
        var running: Set<String> = []
        for (record, output) in journal.unfinished() where !active.contains(record.id) {
            let isFresh = now().timeIntervalSince(record.startedAt) < Self.abandonedAfter
            if output == nil, isFresh, record.pid.map(RunJournal.isAlive) ?? true {
                running.insert(record.pullRequestID)
                continue
            }
            if let output, let result = try? ClaudeResult(data: output) {
                var succeeded = !result.isError
                if record.kind == .review {
                    succeeded = (try? library.store(try result.review(), for: record, reviewedAt: now())) != nil
                }
                log(result.usage, for: record, succeeded: succeeded)
            }
            journal.finish(record.id)
        }
        stillRunning = running
    }

    private func run(_ pullRequest: PullRequest) async {
        let options = RunOptions(model: model, maxBudgetUSD: maxRunBudget)
        defer { working[pullRequest.id] = nil }
        // From here the run journal keeps track of it, not the queue.
        preferences.reviewQueue.removeAll { $0 == pullRequest.id }
        // Many requests can arrive at once; past the daily budget they wait for a manual "Review" or the next day.
        if automatic.remove(pullRequest.id) != nil, spentToday >= dailyAutoBudget {
            attempted.remove(AutoReviewPolicy.attemptKey(pullRequest))
            heldByBudget.insert(pullRequest.id)
            return
        }

        var current = RunRecord(kind: .review, pullRequest: pullRequest, startedAt: now())
        do {
            working[pullRequest.id] = .reviewing
            let repo = pullRequest.repository.nameWithOwner
            let diff = DiffAnnotator.annotate(try await source.fetchDiff(repo: repo, number: pullRequest.number))
            try library.writeInputs(for: pullRequest, diff: diff)

            let input = ReviewInput.make(pullRequest: pullRequest, language: language, diff: diff)
            let (review, spent) = try await engine.review(input: input, schema: try skill.schema(), options: options,
                                                          sink: begin(current))
            try library.store(review, for: current, reviewedAt: now())
            end(current, spent, succeeded: true)

            guard makeLessons else { return }
            current = RunRecord(kind: .lesson, pullRequest: pullRequest, startedAt: now())
            working[pullRequest.id] = .teaching
            let prompt = try skill.lessonPrompt(repo: repo, number: pullRequest.number, title: pullRequest.title)
            let lessonCost = try await engine.lesson(in: library.directory(for: pullRequest), prompt: prompt,
                                                     options: options, sink: begin(current))
            end(current, lessonCost, succeeded: true)
            library.refreshLesson(for: pullRequest)
        } catch {
            end(current, (error as? ClaudeError)?.usage, succeeded: false)
            // A failed lesson does not take the finished review away.
            if current.kind == .review || library.reviews[pullRequest.id] == nil {
                failures[pullRequest.id] = error.localizedDescription
            }
        }
    }

    private func begin(_ record: RunRecord) -> RunSink {
        active.insert(record.id)
        return journal.begin(record)
    }

    private func end(_ record: RunRecord, _ spent: ClaudeUsage?, succeeded: Bool) {
        if let spent { log(spent, for: record, succeeded: succeeded) }
        journal.finish(record.id)
        active.remove(record.id)
    }

    private func log(_ spent: ClaudeUsage, for record: RunRecord, succeeded: Bool) {
        let entry = UsageEntry(date: now(), repo: record.repo, number: record.number, kind: record.kind,
                               usage: spent, succeeded: succeeded)
        usageStore.append(entry)
        usage.append(entry)
    }
}
