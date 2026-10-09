import DashboardCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case mine = "My PRs"
    case reviews = "Reviews"
    case updates = "Updates"
    case code = "Code this week"
    case claude = "Claude reviews"
    case usage = "Claude usage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .mine: return "arrow.triangle.pull"
        case .reviews: return "eye"
        case .updates: return "bell"
        case .code: return "plusminus"
        case .claude: return "sparkles"
        case .usage: return "gauge.with.dots.needle.33percent"
        }
    }
}

struct RootView: View {
    @Environment(DashboardStore.self) private var store
    /// Present only where Claude Code can run.
    @Environment(ReviewCoordinator.self) private var coordinator: ReviewCoordinator?
    @State private var pane: Pane? = .overview
    @State private var showsSettings = false

    var body: some View {
        NavigationSplitView {
            List(panes, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .navigationTitle("Dashboard")
        } detail: {
            detail
                .navigationTitle(pane?.rawValue ?? "")
                #if os(macOS)
                .navigationSubtitle(subtitle)
                #endif
                .toolbar { toolbar }
        }
        #if os(iOS)
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .toolbar { Button("Done") { showsSettings = false } }
            }
        }
        #endif
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if store.newTotal > 0 {
                Button("Mark all read", systemImage: "checkmark.circle") { store.markAllRead() }
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
            #if os(iOS)
            Button("Settings", systemImage: "gearshape") { showsSettings = true }
            #endif
        }
    }

    private var panes: [Pane] {
        Pane.allCases.filter { coordinator != nil || ($0 != .claude && $0 != .usage) }
    }

    private var subtitle: String {
        if store.isLoading { return "Refreshing…" }
        guard let date = store.lastRefresh, let dashboard = store.dashboard else { return "" }
        return "@\(dashboard.viewer) · updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func badge(for pane: Pane) -> Int {
        switch pane {
        case .mine: return store.dashboard?.mineTotal ?? 0
        case .reviews: return store.dashboard?.reviewsTotal ?? 0
        case .updates: return store.newTotal
        case .claude: return coordinator?.pending.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        if let dashboard = store.dashboard {
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.yellow.opacity(0.2))
                }
                switch pane ?? .overview {
                case .overview: OverviewView(dashboard: dashboard, pane: $pane)
                case .mine: PullRequestList(pullRequests: dashboard.mine, showsAuthor: false)
                case .reviews: PullRequestList(pullRequests: dashboard.reviews, showsAuthor: true)
                case .updates: UpdatesView(events: store.feed)
                case .code: CodeView(stats: store.stats, weekStart: dashboard.weekStart)
                case .claude:
                    if let coordinator { ClaudeReviewsView(coordinator: coordinator, dashboard: dashboard) }
                case .usage:
                    if let coordinator { ClaudeUsageView(coordinator: coordinator, weekStart: dashboard.weekStart) }
                }
            }
            .refreshable { await store.refresh() }
        } else if store.needsToken {
            ContentUnavailableView {
                Label("Connect GitHub", systemImage: "key")
            } description: {
                Text(store.errorMessage ?? "")
            } actions: {
                #if os(macOS)
                SettingsLink { Text("Open Settings") }
                #else
                Button("Open Settings") { showsSettings = true }
                #endif
            }
        } else if let error = store.errorMessage {
            ContentUnavailableView {
                Label("Could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.refresh() } }
            }
        } else {
            ProgressView("Loading from GitHub…")
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Environment(DashboardStore.self) private var store
    let dashboard: Dashboard
    @Binding var pane: Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    Tile(title: "My open PRs", value: "\(dashboard.mineTotal)", icon: Pane.mine.icon) { pane = .mine }
                    Tile(title: "Awaiting my review", value: "\(dashboard.reviewsTotal)", icon: Pane.reviews.icon) {
                        pane = .reviews
                    }
                    Tile(title: "New updates", value: "\(store.newTotal)", icon: Pane.updates.icon,
                         tint: store.newTotal > 0 ? .blue : .primary) { pane = .updates }
                    Tile(title: "Lines this week", value: store.stats.map { "+\($0.additions.formatted())" } ?? "…",
                         secondary: store.stats.map { "−\($0.deletions.formatted())" }, icon: Pane.code.icon,
                         tint: .green) {
                        pane = .code
                    }
                }

                GroupBox("Code by day") {
                    WeekChart(stats: store.stats).frame(height: 140).padding(.top, 6)
                }

                GroupBox("Latest updates") {
                    let events = Array(store.feed.prefix(8))
                    if events.isEmpty {
                        Text("All quiet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(events) { event in
                                EventRow(event: event).padding(.vertical, 6)
                                if event.id != events.last?.id { Divider() }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct Tile: View {
    let title: String
    let value: String
    var secondary: String?
    let icon: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                    if let secondary {
                        Text(secondary).font(.system(.title3, design: .rounded)).foregroundStyle(.red)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
