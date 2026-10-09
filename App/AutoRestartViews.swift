import DashboardCore
import SwiftUI

/// The switch for all my pull requests, with counts that narrow the list below.
struct AutoRestartStrip: View {
    @Environment(AutoRestarter.self) private var restarter
    let pullRequests: [PullRequest]
    @Binding var filter: AutoRestarter.Filter?

    var body: some View {
        @Bindable var restarter = restarter

        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Toggle("Auto-restart failed jobs", isOn: $restarter.restartAll)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                    ForEach(AutoRestarter.Filter.allCases) { chip($0) }
                    if restarter.serverURL == nil || !restarter.hasToken || restarter.user.isEmpty {
                        // Without the sign-in nothing can be restarted, so say where it goes.
                        #if os(macOS)
                        SettingsLink { Text("Set up Jenkins…") }.controlSize(.small)
                        #else
                        Text("Set up Jenkins in Settings").font(.caption).foregroundStyle(.secondary)
                        #endif
                    }
                }
                .padding(.horizontal, 12)
            }
            if let error = restarter.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .task { await restarter.checkToken() }
    }

    @ViewBuilder private func chip(_ kind: AutoRestarter.Filter) -> some View {
        let count = pullRequests.filter { restarter.matches($0, kind) }.count
        let isOn = filter == kind
        // Failed and running always show; the other two only once there is something to say.
        if count > 0 || isOn || kind == .failed || kind == .running {
            Button {
                filter = isOn ? nil : kind
            } label: {
                Label("\(count) \(kind.title)", systemImage: kind.icon)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(isOn ? kind.color.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(isOn ? kind.color : .clear))
                    .foregroundStyle(count > 0 ? kind.color : .secondary)
            }
            .buttonStyle(.plain)
            .help(isOn ? "Show all my pull requests" : "Show only these pull requests")
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}

extension AutoRestarter.Filter {
    var title: String {
        switch self {
        case .failed: return "failed"
        case .running: return "running"
        case .restarted: return "restarted"
        case .gaveUp: return "gave up"
        }
    }

    var icon: String {
        switch self {
        case .failed: return "xmark.circle.fill"
        case .running: return "clock.fill"
        case .restarted: return "arrow.clockwise"
        case .gaveUp: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .failed: return .red
        case .running, .restarted: return .orange
        case .gaveUp: return .purple
        }
    }
}

/// Every check of the head commit as one segment, the way GitHub draws them: passed, restarting, running, failed.
struct CheckBar: View {
    @Environment(AutoRestarter.self) private var restarter
    let pullRequest: PullRequest

    var body: some View {
        let lines = restarter.lines(for: pullRequest).sorted { ($0.status.barOrder, $0.check.name) < ($1.status.barOrder, $1.check.name) }
        if lines.isEmpty {
            // Data saved before checks were listed only has the overall state.
            if let state = pullRequest.ci { CIStateIcon(state: state) }
        } else {
            HStack(spacing: lines.count > 30 ? 1 : 2) {
                ForEach(lines) { line in
                    RoundedRectangle(cornerRadius: 2).fill(line.status.color)
                        .help("\(line.check.name) · \(line.note(limit: restarter.limit))")
                }
            }
            .frame(width: 150, height: 10)
            .accessibilityElement()
            .accessibilityLabel("Checks")
            .accessibilityValue(AutoRestarter.Line.counts(lines))
        }
    }
}

struct CIStateIcon: View {
    let state: PullRequest.CIState

    var body: some View {
        switch state {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed")
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed")
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        }
    }
}

/// The selected pull request's checks beside the list: what did not pass, a restart for each, the pull
/// request's own switch and what auto-restart did so far.
struct ChecksPanel: View {
    @Environment(AutoRestarter.self) private var restarter
    @Environment(\.openURL) private var openURL
    let pullRequest: PullRequest
    /// All my pull requests, for the list of jobs.
    let pullRequests: [PullRequest]
    let open: () -> Void
    let close: () -> Void
    @State private var showsJobs = false

    var body: some View {
        let lines = restarter.lines(for: pullRequest)
        let unfinished = lines.filter { $0.status != .passed }
        let events = restarter.history(for: pullRequest)

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(String(pullRequest.number)) · checks on \(String(pullRequest.headRefOid.prefix(7)))")
                            .font(.headline)
                        Text(pullRequest.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(lines.isEmpty ? "No checks reported for this commit" : AutoRestarter.Line.counts(lines))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close")
                        .accessibilityLabel("Close")
                }
                Toggle("Auto-restart this PR (\(restarter.limit) per job)", isOn: Binding(
                    get: { restarter.isEnabled(pullRequest) },
                    set: { restarter.setEnabled(pullRequest, $0) }
                ))
                VStack(spacing: 0) {
                    ForEach(unfinished) { line in
                        Divider()
                        row(line).padding(.vertical, 5)
                    }
                }
                if unfinished.isEmpty, !lines.isEmpty {
                    Label("Every check passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                if let error = restarter.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Button("Which jobs restart…") { showsJobs = true }
                    .buttonStyle(.borderless)
                    .font(.caption)

                Text("History").font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    .padding(.top, 4)
                if events.isEmpty {
                    Text("Nothing was restarted on this pull request yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(events.prefix(12)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(event.date.formatted(Calendar.current.isDateInToday(event.date)
                            ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated)))
                            .monospacedDigit()
                        Image(systemName: event.kind.icon).foregroundStyle(event.kind.color).frame(width: 12)
                        Text(event.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(event.detail ?? "")
                }

                Button("Open on GitHub", action: open)
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.secondary.opacity(0.05))
        .sheet(isPresented: $showsJobs) { JobsSheet(pullRequests: pullRequests).environment(restarter) }
    }

    private func row(_ line: AutoRestarter.Line) -> some View {
        HStack(spacing: 8) {
            Image(systemName: line.status.icon).foregroundStyle(line.status.color).frame(width: 14)
            Button {
                if let url = line.check.url { openURL(url) }
            } label: {
                Text(line.check.name.withoutJenkinsPrefix).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(line.check.url == nil)
            .help("\(line.check.name) — open in Jenkins")
            Spacer(minLength: 6)
            Text(line.detail(limit: restarter.limit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if line.canRestart {
                Button("Restart") {
                    Task { await restarter.restartNow(pullRequest, check: line.check.name) }
                }
                .controlSize(.small)
            }
        }
    }
}

/// The per-job switches and how restarts of each job ended.
struct JobsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pullRequests: [PullRequest]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Which jobs restart").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            List { JobsSection(pullRequests: pullRequests) }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

extension String {
    /// A check's name without the part every Jenkins check of a pull request shares.
    var withoutJenkinsPrefix: String {
        for prefix in ["jenkins/prs/", "jenkins/"] where hasPrefix(prefix) && count > prefix.count {
            return String(dropFirst(prefix.count))
        }
        return self
    }
}

extension AutoRestartPolicy.Event {
    var text: String {
        let name = check.withoutJenkinsPrefix
        switch kind {
        case .requested: return "\(name) restart requested"
        case .refused: return "\(name) was not restarted"
        case .passed: return "\(name) passed after restart"
        case .failedAgain: return "\(name) failed again"
        case .gaveUp: return "\(name) failed again; gave up after \(count)"
        }
    }
}

extension AutoRestartPolicy.Event.Kind {
    var icon: String {
        switch self {
        case .requested: return "arrow.clockwise"
        case .refused: return "exclamationmark.triangle.fill"
        case .passed: return "checkmark"
        case .failedAgain, .gaveUp: return "xmark"
        }
    }

    var color: Color {
        switch self {
        case .requested: return .blue
        case .refused: return .orange
        case .passed: return .green
        case .failedAgain, .gaveUp: return .red
        }
    }
}

extension AutoRestarter.Line {
    /// "9 passed · 5 failed · 1 running · 1 restarting", leaving out what there is none of.
    static func counts(_ lines: [AutoRestarter.Line]) -> String {
        func count(_ statuses: AutoRestarter.Line.Status...) -> Int { lines.filter { statuses.contains($0.status) }.count }
        return [(count(.passed), "passed"), (count(.failed, .gaveUp), "failed"), (count(.running), "running"),
                (count(.restarting), "restarting")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// What the panel says next to the check's name.
    func detail(limit: Int) -> String {
        let count = restarts > 0 ? "↻ \(restarts)/\(limit)" : ""
        switch status {
        case .restarting:
            let time = asked.map { "asked \($0.formatted(.dateTime.hour().minute()))" } ?? "asked"
            return [count, time].filter { !$0.isEmpty }.joined(separator: " · ")
        case .running: return ["running", count].filter { !$0.isEmpty }.joined(separator: " · ")
        case .gaveUp: return "gave up " + count
        case .failed: return autoOff ? "auto off for job" : count
        case .passed, .unknown: return ""
        }
    }

    /// What happened to the check, in a few words.
    func note(limit: Int) -> String {
        let count = restarts > 0 ? " · ↻ \(restarts)/\(limit)" : ""
        switch status {
        case .failed: return "failed" + count
        case .restarting: return "restart requested" + count
        case .gaveUp: return "gave up" + count
        case .running: return "running" + count
        case .passed: return "passed" + count
        case .unknown: return ""
        }
    }
}

extension AutoRestarter.Line.Status {
    var icon: String {
        switch self {
        case .failed: return "xmark.circle.fill"
        case .restarting: return "arrow.clockwise.circle.fill"
        case .gaveUp: return "exclamationmark.triangle.fill"
        case .running: return "clock.fill"
        case .passed: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .failed, .gaveUp: return .red
        case .restarting: return .blue
        case .running: return .orange
        case .passed: return .green
        case .unknown: return .gray
        }
    }

    /// Left to right in the check bar.
    var barOrder: Int {
        switch self {
        case .passed: return 0
        case .unknown: return 1
        case .restarting: return 2
        case .running: return 3
        case .failed, .gaveUp: return 4
        }
    }
}

/// Every Jenkins job of my pull requests: how it stands, how its restarts ended, and its own switch.
struct JobsSection: View {
    @Environment(AutoRestarter.self) private var restarter
    let pullRequests: [PullRequest]
    @State private var showsQuiet = false

    var body: some View {
        let jobs = restarter.jobs(in: pullRequests)
        // A job that passes everywhere, was never restarted and is switched on has nothing to say.
        let loud = jobs.filter {
            $0.failing + $0.running > 0 || restarter.outcomes[$0.name] != nil || !restarter.isCheckEnabled($0.name)
        }
        let shown = showsQuiet ? jobs : loud

        if !jobs.isEmpty {
            Section {
                ForEach(shown) { row($0) }
                if jobs.count > loud.count {
                    Button(showsQuiet ? "Hide passing jobs" : "Show \(jobs.count - loud.count) passing jobs") {
                        showsQuiet.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } header: {
                HStack {
                    Text("Jenkins jobs")
                    Spacer()
                    Text("passed after restart").frame(width: 130, alignment: .trailing)
                    Text("auto-restart").frame(width: 76, alignment: .trailing)
                }
            }
        }
    }

    private func row(_ job: AutoRestartPolicy.Job) -> some View {
        let outcome = restarter.outcomes[job.name]
        return HStack(spacing: 10) {
            Text(job.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if job.failing > 0 {
                Label("\(job.failing)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    .help("Failing on \(job.failing) of my pull requests")
            }
            if job.running > 0 {
                Label("\(job.running)", systemImage: "clock.fill").foregroundStyle(.orange)
                    .help("Running on \(job.running) of my pull requests")
            }
            if job.failing + job.running == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Passing everywhere")
            }
            Text(outcome.map { "\($0.passed) of \($0.total)" } ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
                .help("Restarted runs that passed, out of those that finished")
            Toggle("Auto-restart \(job.name)", isOn: Binding(
                get: { restarter.isCheckEnabled(job.name) },
                set: { restarter.setCheckEnabled(job.name, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 76, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .labelStyle(.titleAndIcon)
    }
}
