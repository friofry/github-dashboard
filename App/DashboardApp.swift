import DashboardCore
import SwiftUI
import UserNotifications

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
                .environment(model.restarter)
                .environment(model.notifier)
                .environment(\.buildCommit, model.config.commit)
                .frame(minWidth: 1040, minHeight: 560)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .environment(model.reviews)
                .environment(model.restarter)
                .environment(model.notifier)
        } label: {
            // Failed or held-back Claude reviews and failed restarts show here too, so they are seen without opening the window.
            Image(systemName: store.errorMessage == nil && (model.reviews?.alerts ?? []).isEmpty
                && model.restarter.lastError == nil
                ? "arrow.triangle.pull" : "exclamationmark.triangle")
            if store.newTotal > 0 { Text("\(store.newTotal)") }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(model.reviews)
                .environment(model.restarter)
                .environment(model.notifier)
                .environment(\.buildCommit, model.config.commit)
                .frame(width: 480)
        }
        #else
        WindowGroup {
            RootView()
                .environment(store)
                .environment(model.restarter)
                .environment(model.notifier)
                .environment(\.buildCommit, model.config.commit)
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
    let restarter: AutoRestarter
    let notifier: Notifier

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
        let restarter = AutoRestarter(
            client: JenkinsClient(),
            tokenStore: KeychainTokenStore(service: config.bundleIdentifier, account: "jenkins-token"),
            preferences: preferences
        )
        self.restarter = restarter
        notifier = Notifier(source: service, poster: SystemNotifications(), preferences: preferences)
        store.onLoaded = { [reviews] dashboard, reviewed in
            reviews?.sync(with: dashboard, reviewed: reviewed)
            Task { await restarter.sync(mine: dashboard.mine) }
        }
        store.startAutoRefresh()
        notifier.start { [store] in store.dashboard?.viewer }
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
    @Environment(AutoRestarter.self) private var restarter
    @Environment(Notifier.self) private var notifier

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
        if let error = restarter.lastError {
            Text(error)
            Divider()
        }
        if let error = notifier.lastError {
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

/// Shows alerts in Notification Center and opens the pull request when one is clicked.
@MainActor
final class SystemNotifications: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        // Set at launch, so a click that starts the app is still delivered here.
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ alert: NotificationAlert) async throws {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.userInfo = ["url": alert.url.absoluteString]
        try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: text), url.scheme == "https", url.host == "github.com"
        else { return }
        await MainActor.run {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }
}
