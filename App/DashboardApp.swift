import DashboardCore
import SwiftUI

@main
struct DashboardApp: App {
    @State private var store = DashboardApp.makeStore()

    /// The only place where live dependencies are wired together.
    private static func makeStore() -> DashboardStore {
        let config = AppConfig()
        let keychain = KeychainTokenStore(service: config.bundleIdentifier)
        var providers: [TokenProvider] = [keychain, StaticTokenProvider(config.environmentToken)]
        #if os(macOS)
        providers.append(GitHubCLITokenProvider())
        #endif
        let store = DashboardStore(
            service: GitHubService(tokens: TokenChain(providers)),
            preferences: UserDefaultsPreferences(config: config),
            tokenStore: keychain
        )
        store.startAutoRefresh()
        return store
    }

    var body: some Scene {
        #if os(macOS)
        Window("GitHub Dashboard", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
        }

        MenuBarExtra {
            MenuBarContent().environment(store)
        } label: {
            Image(systemName: store.errorMessage == nil ? "arrow.triangle.pull" : "exclamationmark.triangle")
            if store.newTotal > 0 { Text("\(store.newTotal)") }
        }

        Settings {
            SettingsView().environment(store).frame(width: 480)
        }
        #else
        WindowGroup {
            RootView().environment(store)
        }
        #endif
    }
}

#if os(macOS)
struct MenuBarContent: View {
    @Environment(DashboardStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let dashboard = store.dashboard {
            Text("My PRs: \(dashboard.mineTotal) · Reviews: \(dashboard.reviewsTotal)")
            Text("New updates: \(store.newTotal)")
            if let stats = store.stats {
                Text("This week: +\(stats.additions) −\(stats.deletions)")
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
