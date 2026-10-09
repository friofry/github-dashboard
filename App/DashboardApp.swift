import DashboardCore
import SwiftUI

@main
struct DashboardApp: App {
    @State private var model = AppModel()
    private var store: DashboardStore { model.store }

    var body: some Scene {
        #if os(macOS)
        Window("GitHub Dashboard", id: "main") {
            RootView()
                .environment(store)
                .environment(model.reviews)
                .environment(\.buildCommit, model.config.commit)
                .frame(minWidth: 1040, minHeight: 560)
        }

        MenuBarExtra {
            MenuBarContent().environment(store).environment(model.reviews)
        } label: {
            // Failed or held-back Claude reviews show here too, so they are seen without opening the window.
            Image(systemName: store.errorMessage == nil && (model.reviews?.alerts ?? []).isEmpty
                ? "arrow.triangle.pull" : "exclamationmark.triangle")
            if store.newTotal > 0 { Text("\(store.newTotal)") }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(model.reviews)
                .environment(\.buildCommit, model.config.commit)
                .frame(width: 480)
        }
        #else
        WindowGroup {
            RootView().environment(store).environment(\.buildCommit, model.config.commit)
        }
        #endif
    }
}

/// The only place where live dependencies are wired together.
@MainActor
final class AppModel {
    let config: AppConfig
    let store: DashboardStore
    /// Nil where Claude Code cannot run (iOS).
    let reviews: ReviewCoordinator?

    init() {
        let config = AppConfig()
        self.config = config
        let preferences = UserDefaultsPreferences(config: config)
        let keychain = KeychainTokenStore(service: config.bundleIdentifier)
        var providers: [TokenProvider] = [keychain, StaticTokenProvider(config.environmentToken)]
        #if os(macOS)
        providers.append(GitHubCLITokenProvider())
        #endif
        let service = GitHubService(tokens: TokenChain(providers))
        store = DashboardStore(service: service, preferences: preferences, tokenStore: keychain)
        reviews = Self.makeReviews(service: service, preferences: preferences, config: config)
        store.onLoaded = { [reviews] dashboard, reviewed in reviews?.sync(with: dashboard, reviewed: reviewed) }
        store.startAutoRefresh()
    }

    private static func makeReviews(service: GitHubService, preferences: UserDefaultsPreferences,
                                    config: AppConfig) -> ReviewCoordinator? {
        #if os(macOS)
        guard let skills = Bundle.main.url(forResource: "skills", withExtension: nil),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let skill = ReviewSkill(directory: skills.appendingPathComponent("pr-review"))
        let home = support.appendingPathComponent(config.bundleIdentifier)
        return ReviewCoordinator(
            source: service,
            publisher: service,
            engine: ClaudeCLI(skill: skill, workDirectory: home.appendingPathComponent("claude"),
                              environment: config.environment),
            skill: skill,
            workspace: ReviewWorkspace(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("learn")),
            journal: RunJournal(directory: home.appendingPathComponent("runs")),
            usageStore: FileUsageStore(file: home.appendingPathComponent("usage.json")),
            preferences: preferences
        )
        #else
        return nil
        #endif
    }
}

private struct BuildCommitKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The commit the running app was built from; empty when it was built without the run scripts.
    var buildCommit: String {
        get { self[BuildCommitKey.self] }
        set { self[BuildCommitKey.self] = newValue }
    }
}

#if os(macOS)
struct MenuBarContent: View {
    @Environment(DashboardStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(ReviewCoordinator.self) private var coordinator: ReviewCoordinator?

    var body: some View {
        if let dashboard = store.dashboard {
            Text("My PRs: \(dashboard.mineTotal) · Reviews: \(dashboard.reviewsTotal)")
            Text("New updates: \(store.newTotal)")
            if let stats = store.stats {
                Text("This week: +\(stats.additions) −\(stats.deletions)")
            }
            if let coordinator {
                let today = UsageTotals(coordinator.usage, since: Calendar.current.startOfDay(for: .now))
                Text("Claude today: \(today.tokens.formatted(.number.notation(.compactName))) tokens, \(today.runs) runs")
            }
            Divider()
        }
        if let error = store.errorMessage {
            Text(error)
            Divider()
        }
        if let alerts = coordinator?.alerts, !alerts.isEmpty {
            ForEach(alerts, id: \.self) { Text($0) }
            Divider()
        }
        Button("Open GitHub Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await store.refresh() } }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

extension ReviewCoordinator {
    /// Problems with Claude reviews worth seeing from the menu bar.
    var alerts: [String] {
        var alerts: [String] = []
        if failedCount > 0 {
            alerts.append(failedCount == 1 ? "1 Claude review failed" : "\(failedCount) Claude reviews failed")
        }
        if !heldByBudget.isEmpty {
            let count = heldByBudget.count
            alerts.append("Daily Claude limit reached: \(count) automatic review\(count == 1 ? "" : "s") waiting")
        }
        return alerts
    }
}
#endif
