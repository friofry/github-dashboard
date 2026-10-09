import Foundation

public enum ClaudeError: LocalizedError {
    case notInstalled
    /// The run ended without a usable answer. Usage is kept because a failed run still costs tokens.
    case failed(String, ClaudeUsage?)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Claude Code is not installed. Install it and run `claude` once to sign in."
        case .failed(let message, _): return message
        }
    }

    public var usage: ClaudeUsage? {
        if case .failed(_, let usage) = self { return usage }
        return nil
    }
}

public struct RunOptions: Sendable {
    public var model: String
    public var maxBudgetUSD: Double

    public init(model: String = "", maxBudgetUSD: Double = 3) {
        self.model = model
        self.maxBudgetUSD = maxBudgetUSD
    }
}

public protocol ReviewEngine: Sendable {
    /// Runs the `pr-review` skill on a prepared input block. The model gets no tools.
    /// - Parameter sink: where the run's output goes so that it outlives the app; nil keeps it in memory.
    func review(input: String, schema: String, options: RunOptions, sink: RunSink?) async throws -> (Review, ClaudeUsage)
    /// Runs the `teach` skill inside a lesson folder; it may only read and write files there.
    func lesson(in directory: URL, prompt: String, options: RunOptions, sink: RunSink?) async throws -> ClaudeUsage
}

/// The JSON object `claude -p --output-format json` prints when it finishes.
public struct ClaudeResult: Sendable {
    public let isError: Bool
    public let text: String
    public let structuredOutput: Data?
    public let usage: ClaudeUsage

    public init(data: Data) throws {
        var object = try JSONSerialization.jsonObject(with: data)
        if let events = object as? [Any], let last = events.last { object = last }
        guard let result = object as? [String: Any] else {
            throw ClaudeError.failed("Claude returned output in an unexpected format.", nil)
        }
        isError = result["is_error"] as? Bool ?? false
        text = result["result"] as? String ?? ""
        structuredOutput = result["structured_output"].flatMap { output in
            JSONSerialization.isValidJSONObject(output) ? try? JSONSerialization.data(withJSONObject: output) : nil
        }

        var usage = ClaudeUsage()
        let tokens = result["usage"] as? [String: Any] ?? [:]
        usage.inputTokens = tokens["input_tokens"] as? Int ?? 0
        usage.outputTokens = tokens["output_tokens"] as? Int ?? 0
        usage.cacheReadTokens = tokens["cache_read_input_tokens"] as? Int ?? 0
        usage.cacheWriteTokens = tokens["cache_creation_input_tokens"] as? Int ?? 0
        usage.costUSD = result["total_cost_usd"] as? Double ?? 0
        usage.durationMs = result["duration_ms"] as? Int ?? 0
        let models = result["modelUsage"] as? [String: [String: Any]] ?? [:]
        usage.model = models.max { ($0.value["costUSD"] as? Double ?? 0) < ($1.value["costUSD"] as? Double ?? 0) }?.key ?? ""
        self.usage = usage
    }

    public func review() throws -> Review {
        guard !isError else { throw ClaudeError.failed(text.isEmpty ? "Claude reported an error." : text, usage) }
        guard let data = structuredOutput ?? text.data(using: .utf8),
              let review = try? JSONDecoder().decode(Review.self, from: data)
        else { throw ClaudeError.failed("Claude's answer did not match the review form.", usage) }
        return review
    }
}

#if os(macOS)
/// Drives the Claude Code CLI installed on this Mac, using whatever account it is signed in to.
public struct ClaudeCLI: ReviewEngine {
    private static let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude",
                                     "~/.claude/local/claude"]
    private let skill: ReviewSkill
    private let workDirectory: URL
    private let environment: [String: String]

    /// - Parameters:
    ///   - workDirectory: a folder the app owns; the skill is copied into it before each review.
    ///   - environment: the app's environment (`AppConfig.environment`); Claude gets it without the GitHub token.
    public init(skill: ReviewSkill, workDirectory: URL, environment: [String: String]) {
        self.skill = skill
        self.workDirectory = workDirectory
        self.environment = environment
        // Claude can exit before reading its input; writing to the closed pipe must fail, not end the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public static var executable: String? {
        candidates.map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func review(input: String, schema: String, options: RunOptions, sink: RunSink?) async throws -> (Review, ClaudeUsage) {
        try installSkill()
        // No tools and only this folder's settings: the diff is untrusted, and the user's plugins are not needed.
        let arguments = ["-p", "/pr-review", "--output-format", "json", "--tools", "",
                         "--setting-sources", "project", "--json-schema", schema]
        let result = try await run(arguments, options: options, in: workDirectory, input: input, timeout: 600, sink: sink)
        return (try result.review(), result.usage)
    }

    public func lesson(in directory: URL, prompt: String, options: RunOptions, sink: RunSink?) async throws -> ClaudeUsage {
        // File tools only, so nothing the lesson reads can leave the machine; edits are confined to the folder.
        let arguments = ["-p", "/teach \(prompt)", "--output-format", "json",
                         "--tools", "Read,Write,Edit,Glob,Grep", "--permission-mode", "acceptEdits"]
        let result = try await run(arguments, options: options, in: directory, input: "", timeout: 1200, sink: sink)
        guard !result.isError else {
            throw ClaudeError.failed(result.text.isEmpty ? "Claude could not build the lesson." : result.text, result.usage)
        }
        return result.usage
    }

    private func installSkill() throws {
        let skills = workDirectory.appendingPathComponent(".claude/skills")
        let target = skills.appendingPathComponent("pr-review")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: skill.directory, to: target)
    }

    static func claudeEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        // Claude has no use for the GitHub token, so it does not get one.
        environment["GH_TOKEN"] = nil
        environment["GITHUB_TOKEN"] = nil
        return environment
    }

    private func run(_ arguments: [String], options: RunOptions, in directory: URL, input: String,
                     timeout: TimeInterval, sink: RunSink?) async throws -> ClaudeResult {
        guard let executable = Self.executable else { throw ClaudeError.notInstalled }
        var arguments = arguments + ["--max-budget-usd", String(format: "%.2f", options.maxBudgetUSD)]
        if !options.model.isEmpty { arguments += ["--model", options.model] }
        let environment = Self.claudeEnvironment(from: environment)

        return try await Task.detached {
            let process = Process()
            let stdin = Pipe(), stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = stdin
            // To a file when there is a sink: a pipe breaks if the app quits, a file is still there afterwards.
            var outputFile: FileHandle?
            if let sink {
                try FileManager.default.createDirectory(at: sink.output.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: sink.output.path, contents: nil)
                outputFile = try FileHandle(forWritingTo: sink.output)
            }
            process.standardOutput = outputFile ?? stdout
            process.standardError = FileHandle.nullDevice
            process.environment = environment
            try process.run()
            sink?.started(process.processIdentifier)

            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            // Feed stdin from another thread: a large diff would otherwise block before we start reading stdout.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            var data = sink == nil ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
            process.waitUntilExit()
            watchdog.cancel()
            if let sink {
                try? outputFile?.close()
                data = (try? Data(contentsOf: sink.output)) ?? Data()
            }

            guard !data.isEmpty else {
                throw ClaudeError.failed("Claude exited with status \(process.terminationStatus) and no output.", nil)
            }
            return try ClaudeResult(data: data)
        }.value
    }
}
#endif
