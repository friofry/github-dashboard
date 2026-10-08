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

    var usage: ClaudeUsage? {
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
    func review(input: String, schema: String, options: RunOptions) async throws -> (Review, ClaudeUsage)
    /// Runs the `teach` skill inside a lesson folder; it may only read and write files there.
    func lesson(in directory: URL, prompt: String, options: RunOptions) async throws -> ClaudeUsage
}

/// The JSON object `claude -p --output-format json` prints when it finishes.
struct ClaudeResult {
    let isError: Bool
    let text: String
    let structuredOutput: Data?
    let usage: ClaudeUsage

    init(data: Data) throws {
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

    func review() throws -> Review {
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

    /// - Parameter workDirectory: a folder the app owns; the skill is copied into it before each review.
    public init(skill: ReviewSkill, workDirectory: URL) {
        self.skill = skill
        self.workDirectory = workDirectory
    }

    public static var executable: String? {
        candidates.map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func review(input: String, schema: String, options: RunOptions) async throws -> (Review, ClaudeUsage) {
        try installSkill()
        // No tools and only this folder's settings: the diff is untrusted, and the user's plugins are not needed.
        let arguments = ["-p", "/pr-review", "--output-format", "json", "--tools", "",
                         "--setting-sources", "project", "--json-schema", schema]
        let result = try await run(arguments, options: options, in: workDirectory, input: input, timeout: 600)
        return (try result.review(), result.usage)
    }

    public func lesson(in directory: URL, prompt: String, options: RunOptions) async throws -> ClaudeUsage {
        // File tools only, so nothing the lesson reads can leave the machine; edits are confined to the folder.
        let arguments = ["-p", "/teach \(prompt)", "--output-format", "json",
                         "--tools", "Read,Write,Edit,Glob,Grep", "--permission-mode", "acceptEdits"]
        let result = try await run(arguments, options: options, in: directory, input: "", timeout: 1200)
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

    private func run(_ arguments: [String], options: RunOptions, in directory: URL, input: String,
                     timeout: TimeInterval) async throws -> ClaudeResult {
        guard let executable = Self.executable else { throw ClaudeError.notInstalled }
        var arguments = arguments + ["--max-budget-usd", String(format: "%.2f", options.maxBudgetUSD)]
        if !options.model.isEmpty { arguments += ["--model", options.model] }

        return try await Task.detached {
            let process = Process()
            let stdin = Pipe(), stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            try process.run()

            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            // Feed stdin from another thread: a large diff would otherwise block before we start reading stdout.
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            guard !data.isEmpty else {
                throw ClaudeError.failed("Claude exited with status \(process.terminationStatus) and no output.", nil)
            }
            return try ClaudeResult(data: data)
        }.value
    }
}
#endif
