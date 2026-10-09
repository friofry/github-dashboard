import Foundation

/// A Claude run that has started. Kept on disk until its result is taken, so a run survives the app quitting.
public struct RunRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let kind: UsageEntry.Kind
    public let repo: String
    public let number: Int
    public let pullRequestID: String
    public let headSha: String
    public let startedAt: Date
    /// The Claude process, once it is running.
    public var pid: Int32?

    public init(kind: UsageEntry.Kind, pullRequest: PullRequest, startedAt: Date) {
        id = UUID()
        self.kind = kind
        repo = pullRequest.repository.nameWithOwner
        number = pullRequest.number
        pullRequestID = pullRequest.id
        headSha = pullRequest.headRefOid
        self.startedAt = startedAt
    }
}

/// Where an engine puts a run's output so that it outlives the app.
public struct RunSink: Sendable {
    /// Claude's final JSON is written here instead of to a pipe, which would die with the app.
    public let output: URL
    /// Called with the process id as soon as the run is launched.
    public let started: @Sendable (Int32) -> Void

    public init(output: URL, started: @escaping @Sendable (Int32) -> Void) {
        self.output = output
        self.started = started
    }
}

/// One small file per unfinished run plus the file its output goes to.
public final class RunJournal: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private func recordFile(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).run.json") }
    private func outputFile(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).out.json") }

    public func begin(_ record: RunRecord) -> RunSink {
        write(record)
        return RunSink(output: outputFile(record.id)) { [weak self] pid in
            var started = record
            started.pid = pid
            self?.write(started)
        }
    }

    /// The result has been taken (or given up on); forget the run.
    public func finish(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: recordFile(id))
        try? FileManager.default.removeItem(at: outputFile(id))
    }

    /// Runs whose result nobody has taken yet, oldest first, each with whatever output it has produced.
    public func unfinished() -> [(record: RunRecord, output: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasSuffix(".run.json") }
            .compactMap { try? decoder.decode(RunRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { record in
                let data = try? Data(contentsOf: outputFile(record.id))
                return (record, data?.isEmpty == false ? data : nil)
            }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func write(_ record: RunRecord) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(record).write(to: recordFile(record.id), options: .atomic)
    }
}
