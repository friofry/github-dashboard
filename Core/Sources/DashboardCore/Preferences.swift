import Foundation

/// Build-time defaults and process environment, read in one place.
public struct AppConfig: Sendable {
    public let bundleIdentifier: String
    public let defaultOrgs: String
    public let defaultIgnoredLogins: String
    public let environmentToken: String?

    public init(bundleIdentifier: String, defaultOrgs: String = "", defaultIgnoredLogins: String = "",
                environmentToken: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.defaultOrgs = defaultOrgs
        self.defaultIgnoredLogins = defaultIgnoredLogins
        self.environmentToken = environmentToken
    }

    /// `DashboardOrgs` and `DashboardIgnoredLogins` are written into Info.plist from `.env` by the run scripts.
    public init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            bundleIdentifier: bundle.bundleIdentifier ?? "github-dashboard",
            defaultOrgs: bundle.object(forInfoDictionaryKey: "DashboardOrgs") as? String ?? "",
            defaultIgnoredLogins: bundle.object(forInfoDictionaryKey: "DashboardIgnoredLogins") as? String ?? "",
            environmentToken: environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]
        )
    }
}

public protocol PreferencesStore: AnyObject {
    var orgs: String { get set }
    var ignoredLogins: String { get set }
    /// PR id -> when the user last opened it or marked it read.
    var seen: [String: Date] { get set }
}

public final class UserDefaultsPreferences: PreferencesStore {
    private let defaults: UserDefaults
    private let config: AppConfig

    public init(defaults: UserDefaults = .standard, config: AppConfig) {
        self.defaults = defaults
        self.config = config
    }

    public var orgs: String {
        get { defaults.string(forKey: "orgs") ?? config.defaultOrgs }
        set { defaults.set(newValue, forKey: "orgs") }
    }

    public var ignoredLogins: String {
        get { defaults.string(forKey: "ignoredLogins") ?? config.defaultIgnoredLogins }
        set { defaults.set(newValue, forKey: "ignoredLogins") }
    }

    public var seen: [String: Date] {
        get { defaults.dictionary(forKey: "seen") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "seen") }
    }
}

public final class InMemoryPreferences: PreferencesStore {
    public var orgs: String
    public var ignoredLogins: String
    public var seen: [String: Date]

    public init(orgs: String = "", ignoredLogins: String = "", seen: [String: Date] = [:]) {
        self.orgs = orgs
        self.ignoredLogins = ignoredLogins
        self.seen = seen
    }
}
