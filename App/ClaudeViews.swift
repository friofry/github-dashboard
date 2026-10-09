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
        store.sorted(pullRequests.filter { showsDone || !coordinator.doneMarks.isDone($0) })
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
        .onChange(of: current.flatMap { coordinator.library.reviews[$0.id]?.pr?.reviewedAt }) { selectFirstFinding() }
    }

    /// The context card when the review has one, else the first finding; a choice still on the list is kept.
    private func selectFirstFinding() {
        let review = current.flatMap { coordinator.library.reviews[$0.id] }
        let rows = (review?.context == nil ? [] : [FindingColumn.contextID]) + (review?.sortedFindings.map(\.id) ?? [])
        if !rows.contains(where: { $0 == selectedFinding }) { selectedFinding = rows.first }
    }

    private var pullRequestColumn: some View {
        let doneCount = all.filter(coordinator.doneMarks.isDone).count
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
                    if targets.allSatisfy(coordinator.doneMarks.isDone) {
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
        let verb = pullRequests.contains { coordinator.library.reviews[$0.id] == nil } ? "Review" : "Re-review"
        return pullRequests.count == 1 ? "\(verb) with Claude" : "\(verb) \(pullRequests.count) with Claude"
    }

    private func setDone(_ pullRequests: [PullRequest], _ isDone: Bool) {
        withAnimation { pullRequests.forEach { coordinator.doneMarks.set($0, isDone) } }
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
                    .opacity(coordinator.doneMarks.isDone(pullRequest) ? 0.55 : 1)
                    .tag(pullRequest.id)
                }
            }
        }
    }

    private func state(of pullRequest: PullRequest) -> String {
        let counts = coordinator.library.reviews[pullRequest.id].map { review -> String in
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
        let review = coordinator.library.reviews[pullRequest.id]
        if let finding = review?.findings.first(where: { $0.id == selectedFinding }) {
            FindingDetail(coordinator: coordinator, pullRequest: pullRequest, finding: finding,
                          selection: $selectedFinding)
        } else if let review, let context = review.context {
            ContextCard(pullRequest: pullRequest, review: review, context: context,
                        diff: coordinator.library.diff(for: pullRequest))
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

    /// Selection tag of the row that opens the context card; finding ids are `path:line:title`, so it cannot clash.
    static let contextID = "pull-request-context"

    var body: some View {
        VStack(spacing: 0) {
            PullRequestChips(pullRequest: pullRequest)
                .padding([.horizontal, .top], 10)
            if let review = coordinator.library.reviews[pullRequest.id] {
                if let context = review.context {
                    ContextStrip(context: context, isSelected: selection == Self.contextID) { selection = Self.contextID }
                        .padding([.horizontal, .top], 10)
                }
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
            if let lesson = coordinator.library.lessons[pullRequest.id] {
                Button("Lesson", systemImage: "graduationcap") { openURL(lesson) }
                    .labelStyle(.iconOnly).help("Open the lesson for this pull request")
            }
            Button("Open pull request", systemImage: "arrow.up.right.square") { openURL(pullRequest.url) }
                .labelStyle(.iconOnly).help("Open the pull request on GitHub")
            if coordinator.doneMarks.isDone(pullRequest) {
                Button("Not done", systemImage: "arrow.uturn.backward.circle") { coordinator.doneMarks.set(pullRequest, false) }
                    .help("Bring this pull request back")
            } else {
                Button("Done", systemImage: "checkmark.circle") { coordinator.doneMarks.set(pullRequest, true) }
                    .help("Hide until there is new activity in this pull request")
            }
        }
    }
}

/// GitHub-style labels for who opened the pull request and which branch goes into which.
struct PullRequestChips: View {
    @Environment(\.openURL) private var openURL
    let pullRequest: PullRequest

    var body: some View {
        ChipFlow(spacing: 6) {
            if let author = pullRequest.author {
                Button {
                    if let url = Self.profile(author.login) { openURL(url) }
                } label: {
                    Label(author.login, systemImage: author.isBot ? "gearshape" : "person.crop.circle")
                }
                .buttonStyle(.plain)
                .modifier(Chip(tint: .secondary))
                .help("Open @\(author.login) on GitHub")
            }
            if let head = pullRequest.headRefName {
                Text(head).modifier(Chip(tint: .blue)).help("Branch with the changes: \(head)")
            }
            if let base = pullRequest.baseRefName {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary).padding(.top, 3)
                Text(base).modifier(Chip(tint: .blue)).help("Merges into \(base)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Built here from the login alone, so it can only point at github.com.
    static func profile(_ login: String) -> URL? {
        login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "https://github.com/\($0)") }
    }
}

/// The rounded, lightly tinted label GitHub uses for branch names and authors.
struct Chip: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption.monospaced())
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Top of the findings column: the pull request's context in three lines, always in view; opens the full card.
struct ContextStrip: View {
    let context: Review.Context
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("About this change").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                    Text("More").font(.caption).foregroundStyle(.blue)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    row("Why", context.why, .blue)
                    row("Where", context.map?.changed.map(\.name).joined(separator: ", ") ?? context.architecture, .purple)
                    row("What", context.feature, .orange)
                }
                .font(.caption)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Why this pull request exists and where it fits")
    }

    private func row(_ label: String, _ text: String, _ tint: Color) -> some View {
        GridRow {
            Text(label).fontWeight(.semibold).foregroundStyle(tint)
            Text(text).lineLimit(2).foregroundStyle(.primary)
        }
    }
}

/// Right column when the strip is chosen: what the change does, where it sits, and how the files divide up.
struct ContextCard: View {
    let pullRequest: PullRequest
    let review: Review
    let context: Review.Context
    let diff: ParsedDiff?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pullRequest.repository.nameWithOwner) #\(pullRequest.number) · \(pullRequest.title)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Text(context.feature).font(.title3.weight(.semibold)).textSelection(.enabled)
                }

                if let before = context.before, let after = context.after {
                    HStack(alignment: .center, spacing: 8) {
                        change("Before", before, .red)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        change("After", after, .green)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                section("Where it fits") {
                    if let map = context.map, !map.changed.isEmpty {
                        ArchitectureMap(map: map)
                    }
                    Text(context.architecture).foregroundStyle(.secondary).textSelection(.enabled)
                }

                if let layers = context.layers, !layers.isEmpty {
                    section("Layers") { LayerMap(layers: layers, diff: diff) }
                }

                section("Why") { Text(context.why).textSelection(.enabled) }

                if review.findings.isEmpty {
                    Label("No findings", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(pullRequest.id)
    }

    private func change(_ title: String, _ text: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint).textCase(.uppercase)
            Text(text).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

/// What uses the changed code, the changed code itself, and what it relies on, left to right.
struct ArchitectureMap: View {
    let map: Review.Context.Map

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !map.callers.isEmpty {
                column("Used by", map.callers, highlighted: false)
                arrow
            }
            column("Changed here", map.changed, highlighted: true)
            if !map.dependencies.isEmpty {
                arrow
                column("Relies on", map.dependencies, highlighted: false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.secondary)
    }

    private func column(_ title: String, _ nodes: [Review.Context.Node], highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(highlighted ? Color.purple : .secondary)
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(node.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlighted ? Color.purple.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(highlighted ? Color.purple : Color.secondary.opacity(0.35), lineWidth: highlighted ? 1.5 : 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The project's layers the change touches, top to bottom in the order calls flow, with each layer's files.
struct LayerMap: View {
    let layers: [Review.Context.Layer]
    let diff: ParsedDiff?

    var body: some View {
        let named = Set(layers.flatMap(\.paths))
        let rest = diff?.files.map(\.path).filter { !named.contains($0) } ?? []
        let rows = layers + (rest.isEmpty ? [] : [Review.Context.Layer(name: "Other", role: nil, paths: rest, next: nil)])
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, layer in
                lane(layer)
                if index < rows.count - 1 {
                    flow(layer.next ?? "")
                }
            }
        }
    }

    private func lane(_ layer: Review.Context.Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(layer.name).font(.callout.weight(.semibold))
                Spacer()
                if let role = layer.role, !role.isEmpty {
                    Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ChipFlow(spacing: 5) {
                ForEach(layer.paths, id: \.self) { path in
                    HStack(spacing: 5) {
                        Text(path.split(separator: "/").last.map(String.init) ?? path)
                        if let file = diff?.file(path) {
                            Text("\(file.added + file.removed)").foregroundStyle(.purple)
                        }
                    }
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .help(path)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.purple.opacity(0.45)))
    }

    /// The link between two lanes: what one layer hands to the next.
    private func flow(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1.5)
            Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 14).padding(.vertical, 5)
        }
        .padding(.leading, 18)
        .frame(minHeight: 14, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lays its children out in rows, wrapping to the next row when the width runs out.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { row in row.map { $0.size.width }.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)) }.max() ?? 0
        let height = rows.map { row in row.map { $0.size.height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map { $0.size.height }.max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
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
                    UsageTile(title: "Last 12 months", totals: UsageTotals(entries))
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
