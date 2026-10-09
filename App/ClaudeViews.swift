import DashboardCore
import SwiftUI

// MARK: - Reviews

/// Three columns, like a mail client: pull requests, the findings of the selected one, one finding in full.
struct ClaudeReviewsView: View {
    @Environment(DashboardStore.self) private var store
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let dashboard: Dashboard
    @State private var showsDone = false
    /// Several pull requests can be selected at once (shift or command click) and acted on from the context menu.
    @State private var selection: Set<String> = []
    @State private var selectedFinding: String?

    private var all: [PullRequest] { dashboard.reviews + store.reviewed + dashboard.mine }
    /// The one pull request whose findings are shown; nil while none or several are selected.
    private var current: PullRequest? { selection.count == 1 ? all.first { selection.contains($0.id) } : nil }
    private var selected: [PullRequest] { all.filter { selection.contains($0.id) } }

    private func visible(_ pullRequests: [PullRequest]) -> [PullRequest] {
        store.sorted(pullRequests.filter { showsDone || !coordinator.isDone($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            pullRequestColumn.frame(width: 250)
            Divider()
            if let current {
                FindingColumn(coordinator: coordinator, pullRequest: current, selection: $selectedFinding)
                    .frame(width: 280)
                Divider()
                detail(for: current).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selection.count > 1 {
                ContentUnavailableView {
                    Label("\(selection.count) pull requests selected", systemImage: "square.stack")
                } actions: {
                    Button(reviewTitle(for: selected)) { selected.forEach(coordinator.request) }
                    Button("Mark as done") { setDone(selected, true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a pull request", systemImage: "sparkles",
                                       description: Text("Its findings appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection.isEmpty, let first = visible(all).first { selection = [first.id] }
            selectFirstFinding()
        }
        .onChange(of: selection) { selectFirstFinding() }
        // A review that finishes while its pull request is open should show its first finding straight away.
        .onChange(of: current.flatMap { coordinator.reviews[$0.id]?.pr?.reviewedAt }) { selectFirstFinding() }
    }

    private func selectFirstFinding() {
        let findings = current.flatMap { coordinator.reviews[$0.id]?.sortedFindings } ?? []
        if !findings.contains(where: { $0.id == selectedFinding }) { selectedFinding = findings.first?.id }
    }

    private var pullRequestColumn: some View {
        let doneCount = all.filter(coordinator.isDone).count
        return VStack(spacing: 0) {
            List(selection: $selection) {
                section("Awaiting my review", visible(dashboard.reviews))
                section("Reviewed by me", visible(store.reviewed))
                section("My pull requests", visible(dashboard.mine))
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let targets = all.filter { ids.contains($0.id) }
                if !targets.isEmpty {
                    Button(reviewTitle(for: targets), systemImage: "sparkles") { targets.forEach(coordinator.request) }
                    if targets.allSatisfy(coordinator.isDone) {
                        Button("Mark as not done", systemImage: "arrow.uturn.backward.circle") { setDone(targets, false) }
                    } else {
                        Button("Mark as done", systemImage: "checkmark.circle") { setDone(targets, true) }
                    }
                    Divider()
                    Button(targets.count == 1 ? "Open on GitHub" : "Open \(targets.count) on GitHub",
                           systemImage: "arrow.up.right.square") {
                        for pullRequest in targets { openURL(pullRequest.url) }
                    }
                }
            }
            if !coordinator.pending.isEmpty || doneCount > 0 {
                Divider()
                HStack {
                    if !coordinator.pending.isEmpty {
                        Button("Review all (\(coordinator.pending.count))") { coordinator.requestAllPending() }
                            .help("Review every request that has no review of its latest commit")
                    }
                    Spacer()
                    if doneCount > 0 {
                        Toggle("Done (\(doneCount))", isOn: $showsDone)
                            #if os(macOS)
                            .toggleStyle(.checkbox)
                            #endif
                    }
                }
                .controlSize(.small)
                .padding(8)
            }
        }
    }

    private func reviewTitle(for pullRequests: [PullRequest]) -> String {
        let verb = pullRequests.contains { coordinator.reviews[$0.id] == nil } ? "Review" : "Re-review"
        return pullRequests.count == 1 ? "\(verb) with Claude" : "\(verb) \(pullRequests.count) with Claude"
    }

    private func setDone(_ pullRequests: [PullRequest], _ isDone: Bool) {
        withAnimation { pullRequests.forEach { coordinator.setDone($0, isDone) } }
        if isDone, !showsDone { selection.subtract(pullRequests.map(\.id)) }
    }

    @ViewBuilder private func section(_ title: String, _ pullRequests: [PullRequest]) -> some View {
        if !pullRequests.isEmpty {
            Section(title) {
                ForEach(pullRequests) { pullRequest in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pullRequest.title).lineLimit(1)
                        Text("\(pullRequest.repository.nameWithOwner.split(separator: "/").last ?? "") #\(pullRequest.number) · \(state(of: pullRequest))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .opacity(coordinator.isDone(pullRequest) ? 0.55 : 1)
                    .tag(pullRequest.id)
                }
            }
        }
    }

    private func state(of pullRequest: PullRequest) -> String {
        let counts = coordinator.reviews[pullRequest.id].map { review -> String in
            let parts = Finding.Severity.allCases.compactMap { severity -> String? in
                let count = review.findings.filter { $0.severity == severity }.count
                return count > 0 ? "\(count) \(severity.rawValue)" : nil
            }
            return parts.isEmpty ? "no findings" : parts.joined(separator: ", ")
        }
        switch coordinator.status(for: pullRequest) {
        case .none: return "not reviewed"
        case .working(.queued): return "queued"
        case .working(.reviewing): return "reviewing…"
        case .working(.teaching): return "writing lesson…"
        case .current: return counts ?? ""
        case .outdated: return "\(counts ?? "") · new commits"
        case .failed: return "failed"
        }
    }

    @ViewBuilder private func detail(for pullRequest: PullRequest) -> some View {
        let review = coordinator.reviews[pullRequest.id]
        if let finding = review?.findings.first(where: { $0.id == selectedFinding }) {
            FindingDetail(coordinator: coordinator, pullRequest: pullRequest, finding: finding,
                          selection: $selectedFinding)
        } else if let review, review.findings.isEmpty {
            ContentUnavailableView("No findings", systemImage: "checkmark.seal", description: Text(review.summary))
        } else {
            ContentUnavailableView("Select a finding", systemImage: "text.magnifyingglass")
        }
    }
}

/// Middle column: the findings of one pull request and the actions on the pull request itself.
struct FindingColumn: View {
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let pullRequest: PullRequest
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            if let review = coordinator.reviews[pullRequest.id] {
                List(selection: $selection) {
                    Section {
                        ForEach(review.sortedFindings) { finding in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(finding.severity.color).frame(width: 8, height: 8).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title).lineLimit(2)
                                    Text(finding.postedURL == nil
                                        ? "\(finding.category.rawValue) · \(finding.path.split(separator: "/").last ?? ""):\(finding.line)"
                                        : "\(finding.category.rawValue) · published")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .tag(finding.id)
                        }
                    } header: {
                        Text(review.summary).font(.caption).textCase(nil).lineLimit(5).padding(.bottom, 4)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Not reviewed yet", systemImage: "sparkles")
                } description: {
                    if case .failed(let message) = coordinator.status(for: pullRequest) { Text(message) }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            actions.controlSize(.small).padding(8)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            switch coordinator.status(for: pullRequest) {
            case .working(let phase):
                ProgressView().controlSize(.small)
                Text(phase == .queued ? "Queued" : phase == .reviewing ? "Reviewing…" : "Writing lesson…")
                    .font(.caption).foregroundStyle(.secondary)
            case .none: Button("Review") { coordinator.request(pullRequest) }
            case .current: Button("Re-review") { coordinator.request(pullRequest) }
            case .outdated: Button("Re-review new commits") { coordinator.request(pullRequest) }
            case .failed: Button("Retry") { coordinator.request(pullRequest) }
            }
            Spacer()
            if let lesson = coordinator.lessons[pullRequest.id] {
                Button("Lesson", systemImage: "graduationcap") { openURL(lesson) }
                    .labelStyle(.iconOnly).help("Open the lesson for this pull request")
            }
            Button("Open pull request", systemImage: "arrow.up.right.square") { openURL(pullRequest.url) }
                .labelStyle(.iconOnly).help("Open the pull request on GitHub")
            if coordinator.isDone(pullRequest) {
                Button("Not done", systemImage: "arrow.uturn.backward.circle") { coordinator.setDone(pullRequest, false) }
                    .help("Bring this pull request back")
            } else {
                Button("Done", systemImage: "checkmark.circle") { coordinator.setDone(pullRequest, true) }
                    .help("Hide until there is new activity in this pull request")
            }
        }
    }
}

extension Finding.Severity {
    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .gray
        }
    }
}

// MARK: - Usage

struct ClaudeUsageView: View {
    let coordinator: ReviewCoordinator
    let weekStart: Date

    var body: some View {
        let entries = coordinator.usage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    UsageTile(title: "Today", totals: UsageTotals(entries, since: Calendar.current.startOfDay(for: .now)))
                    UsageTile(title: "This week", totals: UsageTotals(entries, since: weekStart))
                    UsageTile(title: "All time", totals: UsageTotals(entries))
                }

                GroupBox("Runs") {
                    if entries.isEmpty {
                        Text("No Claude runs yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("When"); Text("Pull request"); Text("Run"); Text("Model")
                                Text("In").gridColumnAlignment(.trailing)
                                Text("Out").gridColumnAlignment(.trailing)
                                Text("Cached").gridColumnAlignment(.trailing)
                                Text("Cost").gridColumnAlignment(.trailing)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ForEach(entries.reversed().prefix(200)) { entry in
                                GridRow {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(entry.repo) #\(entry.number)").lineLimit(1)
                                    Text(entry.succeeded ? entry.kind.rawValue : "\(entry.kind.rawValue), failed")
                                        .foregroundStyle(entry.succeeded ? Color.primary : .red)
                                    Text(entry.usage.model).lineLimit(1)
                                    Text(entry.usage.inputTokens.formatted())
                                    Text(entry.usage.outputTokens.formatted())
                                    Text((entry.usage.cacheReadTokens + entry.usage.cacheWriteTokens).formatted())
                                    Text(entry.usage.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                                }
                            }
                        }
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }

                Text("Cost is what Claude Code reports at API list prices; on a subscription plan it is an estimate of usage, not a charge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

struct UsageTile: View {
    let title: String
    let totals: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(totals.tokens.formatted(.number.notation(.compactName)) + " tokens")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("\(totals.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))) · \(totals.runs) runs")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Settings

struct ClaudeSettingsSection: View {
    @Bindable var coordinator: ReviewCoordinator

    var body: some View {
        Section {
            Toggle("Review new requests automatically", isOn: $coordinator.autoReview)
            Toggle("Also write a lesson for each review", isOn: $coordinator.makeLessons)
            TextField("Model", text: $coordinator.model, prompt: Text("Claude Code default"))
            TextField("Explanation language", text: $coordinator.language, prompt: Text("English"))
            TextField("Spending limit per run, USD", value: $coordinator.maxRunBudget, format: .number)
            TextField("Daily limit for automatic runs, USD", value: $coordinator.dailyAutoBudget, format: .number)
        } header: {
            Text("Claude reviews")
        } footer: {
            Text("Automatic reviews cover requests that arrive after you switch this on, and new commits in reviewed pull requests; past the daily limit they wait for you. Lessons need the teach skill in Claude Code and cost more than the review itself. A comment is posted to GitHub only when you press Publish and confirm.")
        }
    }
}
