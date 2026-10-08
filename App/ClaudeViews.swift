import DashboardCore
import SwiftUI

// MARK: - Reviews

struct ClaudeReviewsView: View {
    @Environment(DashboardStore.self) private var store
    let coordinator: ReviewCoordinator
    let dashboard: Dashboard
    @State private var showsDone = false

    var body: some View {
        let doneCount = (dashboard.reviews + dashboard.mine).filter(coordinator.isDone).count
        List {
            if doneCount > 0 {
                Toggle("Show \(doneCount) done", isOn: $showsDone)
            }
            if !coordinator.pending.isEmpty {
                HStack {
                    Text("\(coordinator.pending.count) review requests have no review of their latest commit.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review all") { coordinator.requestAllPending() }
                }
            }
            section("Awaiting my review", dashboard.reviews)
            section("My pull requests", dashboard.mine)
        }
    }

    @ViewBuilder private func section(_ title: String, _ pullRequests: [PullRequest]) -> some View {
        let visible = pullRequests.filter { showsDone || !coordinator.isDone($0) }
        if !visible.isEmpty {
            Section(title) {
                ForEach(store.sorted(visible)) { pullRequest in
                    ReviewRow(coordinator: coordinator, pullRequest: pullRequest)
                }
            }
        }
    }
}

struct ReviewRow: View {
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let pullRequest: PullRequest
    @State private var isExpanded = false

    var body: some View {
        let review = coordinator.reviews[pullRequest.id]
        DisclosureGroup(isExpanded: $isExpanded) {
            if let review {
                Text(review.summary).font(.callout).foregroundStyle(.secondary).padding(.vertical, 2)
                ForEach(review.sortedFindings) { finding in
                    FindingCard(coordinator: coordinator, pullRequest: pullRequest, finding: finding)
                }
            } else {
                Text("Not reviewed yet.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open pull request", systemImage: "arrow.up.right.square") { openURL(pullRequest.url) }
                Spacer()
                doneButton
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pullRequest.title).lineLimit(1)
                    Text("\(pullRequest.repository.nameWithOwner) #\(pullRequest.number)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let review { SeverityCounts(findings: review.findings) }
                status
                if let lesson = coordinator.lessons[pullRequest.id] {
                    Button("Lesson", systemImage: "graduationcap") { openURL(lesson) }
                        .labelStyle(.iconOnly).help("Open the lesson for this pull request")
                }
                action
                doneButton.labelStyle(.iconOnly)
            }
            // The whole row opens and closes the findings, not just the small arrow.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }
            .opacity(coordinator.isDone(pullRequest) ? 0.55 : 1)
        }
    }

    @ViewBuilder private var doneButton: some View {
        if coordinator.isDone(pullRequest) {
            Button("Mark as not done", systemImage: "arrow.uturn.backward.circle") {
                coordinator.setDone(pullRequest, false)
            }
            .help("Bring this pull request back")
        } else {
            Button("Mark as done", systemImage: "checkmark.circle") {
                withAnimation { coordinator.setDone(pullRequest, true) }
            }
            .help("Hide until there is new activity in this pull request")
        }
    }

    @ViewBuilder private var status: some View {
        switch coordinator.status(for: pullRequest) {
        case .none: EmptyView()
        case .working(let phase):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(phase == .queued ? "Queued" : phase == .reviewing ? "Reviewing" : "Writing lesson")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .current: EmptyView()
        case .outdated: Badge(text: "New commits", color: .orange)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
        }
    }

    @ViewBuilder private var action: some View {
        switch coordinator.status(for: pullRequest) {
        case .working: EmptyView()
        case .none: Button("Review") { coordinator.request(pullRequest) }
        case .current, .outdated: Button("Re-review") { coordinator.request(pullRequest) }
        case .failed: Button("Retry") { coordinator.request(pullRequest) }
        }
    }
}

struct SeverityCounts: View {
    let findings: [Finding]

    var body: some View {
        if findings.isEmpty {
            Badge(text: "No findings", color: .green)
        } else {
            HStack(spacing: 4) {
                ForEach(Finding.Severity.allCases, id: \.self) { severity in
                    let count = findings.filter { $0.severity == severity }.count
                    if count > 0 { Badge(text: "\(count) \(severity.rawValue)", color: severity.color) }
                }
            }
        }
    }
}

struct FindingCard: View {
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let pullRequest: PullRequest
    let finding: Finding
    @State private var confirmsPublish = false

    var body: some View {
        let link = coordinator.link(for: finding, in: pullRequest)
        let key = ReviewCoordinator.key(finding, in: pullRequest)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Badge(text: finding.severity.rawValue, color: finding.severity.color)
                Badge(text: finding.category.rawValue, color: .secondary)
                Text(finding.title).fontWeight(.semibold)
            }
            Button {
                if let link { openURL(link) }
            } label: {
                Label(location, systemImage: "arrow.up.right.square").font(.caption.monospaced())
            }
            .buttonStyle(.borderless)
            .tint(.blue)
            .disabled(link == nil)

            Text(finding.problem)
            if let example = finding.example, !example.isEmpty {
                labelled("Example", example)
            }
            labelled("Fix", finding.suggestion)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Comment to post").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let posted = finding.postedURL {
                        Button("Published", systemImage: "checkmark.circle.fill") { openURL(posted) }
                            .controlSize(.small).tint(.green).help("Open the comment on GitHub")
                    } else if coordinator.publishing.contains(key) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Publish", systemImage: "paperplane") { confirmsPublish = true }.controlSize(.small)
                    }
                    Button("Copy", systemImage: "doc.on.doc") { copy(finding.comment) }.controlSize(.small)
                }
                if let error = coordinator.publishErrors[key] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                Text(finding.comment)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 6)
        // Posting is public and cannot be taken back from here, so it always asks first.
        .confirmationDialog("Publish this comment?", isPresented: $confirmsPublish) {
            Button("Publish to \(pullRequest.repository.nameWithOwner) #\(pullRequest.number)") {
                Task { await coordinator.publish(finding, in: pullRequest) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be posted under your GitHub account on \(location).")
        }
    }

    private var location: String {
        let range = finding.endLine.map { $0 > finding.line ? "\(finding.line)-\($0)" : "\(finding.line)" } ?? "\(finding.line)"
        return "\(finding.path):\(range)"
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        (Text("\(label): ").foregroundStyle(.secondary) + Text(text)).font(.callout).textSelection(.enabled)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
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
