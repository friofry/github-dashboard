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
                .frame(minWidth: 820, minHeight: 520)
        }

        MenuBarExtra {
            MenuBarContent().environment(store).environment(model.reviews)
        } label: {
            Image(systemName: store.errorMessage == nil ? "arrow.triangle.pull" : "exclamationmark.triangle")
            if store.newTotal > 0 { Text("\(store.newTotal)") }
        }

        Settings {
            SettingsView().environment(store).environment(model.reviews).frame(width: 480)
        }
        #else
        WindowGroup {
            RootView().environment(store)
        }
        #endif
    }
}

/// The only place where live dependencies are wired together.
@MainActor
final class AppModel {
    let store: DashboardStore
    /// Nil where Claude Code cannot run (iOS).
    let reviews: ReviewCoordinator?

    init() {
        let config = AppConfig()
        let preferences = UserDefaultsPreferences(config: config)
        let keychain = KeychainTokenStore(service: config.bundleIdentifier)
        var providers: [TokenProvider] = [keychain, StaticTokenProvider(config.environmentToken)]
        #if os(macOS)
        providers.append(GitHubCLITokenProvider())
        #endif
        let service = GitHubService(tokens: TokenChain(providers))
        store = DashboardStore(service: service, preferences: preferences, tokenStore: keychain)
        reviews = Self.makeReviews(service: service, preferences: preferences, config: config)
        store.onLoaded = { [reviews] dashboard in reviews?.sync(with: dashboard) }
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
            engine: ClaudeCLI(skill: skill, workDirectory: home.appendingPathComponent("claude")),
            skill: skill,
            workspace: ReviewWorkspace(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("learn")),
            usageStore: FileUsageStore(file: home.appendingPathComponent("usage.json")),
            preferences: preferences
        )
        #else
        return nil
        #endif
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
        Button("Open GitHub Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await store.refresh() } }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
#endif
