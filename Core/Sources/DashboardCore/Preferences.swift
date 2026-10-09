import Foundation

/// Build-time defaults and process environment, read in one place.
public struct AppConfig: Sendable {
    public let bundleIdentifier: String
    public let defaultOrgs: String
    public let defaultIgnoredLogins: String
    public let environmentToken: String?
    /// The commit the app was built from, with "-dirty" when the working copy had changes; empty if unknown.
    public let commit: String
    /// The process environment, for child processes the app starts.
    public let environment: [String: String]

    public init(bundleIdentifier: String, defaultOrgs: String = "", defaultIgnoredLogins: String = "",
                environmentToken: String? = nil, commit: String = "", environment: [String: String] = [:]) {
        self.bundleIdentifier = bundleIdentifier
        self.defaultOrgs = defaultOrgs
        self.defaultIgnoredLogins = defaultIgnoredLogins
        self.environmentToken = environmentToken
        self.commit = commit
        self.environment = environment
    }

    /// `DashboardOrgs`, `DashboardIgnoredLogins` and `DashboardCommit` are written into Info.plist by the run scripts.
    public init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            bundleIdentifier: bundle.bundleIdentifier ?? "github-dashboard",
            defaultOrgs: bundle.object(forInfoDictionaryKey: "DashboardOrgs") as? String ?? "",
            defaultIgnoredLogins: bundle.object(forInfoDictionaryKey: "DashboardIgnoredLogins") as? String ?? "",
            environmentToken: environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"],
            commit: bundle.object(forInfoDictionaryKey: "DashboardCommit") as? String ?? "",
            environment: environment
        )
    }
}

public protocol PreferencesStore: AnyObject {
    var orgs: String { get set }
    var ignoredLogins: String { get set }
    /// PR id -> when the user last opened it or marked it read.
    var seen: [String: Date] { get set }
}

public final class UserDefaultsPreferences: PreferencesStore, ReviewPreferences {
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

    public var autoReview: Bool {
        get { defaults.bool(forKey: "autoReview") }
        set { defaults.set(newValue, forKey: "autoReview") }
    }

    public var makeLessons: Bool {
        get { defaults.bool(forKey: "makeLessons") }
        set { defaults.set(newValue, forKey: "makeLessons") }
    }

    public var claudeModel: String {
        get { defaults.string(forKey: "claudeModel") ?? "" }
        set { defaults.set(newValue, forKey: "claudeModel") }
    }

    public var maxRunBudget: Double {
        get { defaults.object(forKey: "maxRunBudget") as? Double ?? 3 }
        set { defaults.set(newValue, forKey: "maxRunBudget") }
    }

    public var dailyAutoBudget: Double {
        get { defaults.object(forKey: "dailyAutoBudget") as? Double ?? 10 }
        set { defaults.set(newValue, forKey: "dailyAutoBudget") }
    }

    public var reviewLanguage: String {
        get { defaults.string(forKey: "reviewLanguage") ?? "" }
        set { defaults.set(newValue, forKey: "reviewLanguage") }
    }

    public var reviewBaseline: [String]? {
        get { defaults.stringArray(forKey: "reviewBaseline") }
        set { defaults.set(newValue, forKey: "reviewBaseline") }
    }

    public var reviewDone: [String: Date] {
        get { defaults.dictionary(forKey: "reviewDone") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "reviewDone") }
    }

    public var reviewQueue: [String] {
        get { defaults.stringArray(forKey: "reviewQueue") ?? [] }
        set { defaults.set(newValue, forKey: "reviewQueue") }
    }
}

public final class InMemoryPreferences: PreferencesStore, ReviewPreferences {
    public var orgs: String
    public var ignoredLogins: String
    public var seen: [String: Date]
    public var autoReview = false
    public var makeLessons = false
    public var claudeModel = ""
    public var maxRunBudget = 3.0
    public var dailyAutoBudget = 10.0
    public var reviewLanguage = ""
    public var reviewBaseline: [String]?
    public var reviewDone: [String: Date] = [:]
    public var reviewQueue: [String] = []

    public init(orgs: String = "", ignoredLogins: String = "", seen: [String: Date] = [:]) {
        self.orgs = orgs
        self.ignoredLogins = ignoredLogins
        self.seen = seen
    }
}
