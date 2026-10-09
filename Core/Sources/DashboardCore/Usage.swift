import Foundation

/// What one Claude run consumed, as the CLI reports it.
public struct ClaudeUsage: Codable, Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var costUSD = 0.0
    public var durationMs = 0
    public var model = ""

    public init() {}

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

public struct UsageEntry: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case review, lesson }

    public var id = UUID()
    public let date: Date
    public let repo: String
    public let number: Int
    public let kind: Kind
    public let usage: ClaudeUsage
    public let succeeded: Bool

    public init(date: Date, repo: String, number: Int, kind: Kind, usage: ClaudeUsage, succeeded: Bool) {
        self.date = date
        self.repo = repo
        self.number = number
        self.kind = kind
        self.usage = usage
        self.succeeded = succeeded
    }
}

public struct UsageTotals: Sendable, Equatable {
    public var runs = 0
    public var tokens = 0
    public var costUSD = 0.0

    public init(_ entries: [UsageEntry], since: Date = .distantPast) {
        for entry in entries where entry.date >= since {
            runs += 1
            tokens += entry.usage.totalTokens
            costUSD += entry.usage.costUSD
        }
    }
}

public protocol UsageStore: AnyObject {
    func load() -> [UsageEntry]
    func append(_ entry: UsageEntry)
}

public final class InMemoryUsageStore: UsageStore {
    private var entries: [UsageEntry]

    public init(_ entries: [UsageEntry] = []) {
        self.entries = entries
    }

    public func load() -> [UsageEntry] { entries }
    public func append(_ entry: UsageEntry) { entries.append(entry) }
}

/// A JSON file of the runs of the last `retention`, newest last.
public final class FileUsageStore: UsageStore {
    /// How long a run stays in the file. The whole file is rewritten on every run, so it must not grow forever.
    public static let retention: TimeInterval = 365 * 86_400

    private let file: URL
    private let now: () -> Date

    public init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
    }

    public func load() -> [UsageEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UsageEntry].self, from: data)) ?? []
    }

    public func append(_ entry: UsageEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cutoff = now().addingTimeInterval(-Self.retention)
        let kept = (load() + [entry]).filter { $0.date >= cutoff }
        try? encoder.encode(kept).write(to: file, options: .atomic)
    }
}
