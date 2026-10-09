import DashboardCore
import SwiftUI

/// The switch for all my pull requests, with counts that narrow the list below.
struct AutoRestartStrip: View {
    @Environment(AutoRestarter.self) private var restarter
    let pullRequests: [PullRequest]
    @Binding var filter: AutoRestarter.Filter?

    var body: some View {
        @Bindable var restarter = restarter
        let restartable = restarter.restartable(in: pullRequests)

        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Toggle("Auto-restart failed jobs", isOn: $restarter.restartAll)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                    ForEach(AutoRestarter.Filter.allCases) { chip($0) }
                    if restartable > 0 {
                        Button("Restart \(restartable) failed") {
                            Task { await restarter.restartAllFailed(in: pullRequests) }
                        }
                        .controlSize(.small)
                        .help("Start every failed Jenkins job of my pull requests again now")
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

/// The overall CI state of my pull request; opens its checks.
struct ChecksButton: View {
    @Environment(AutoRestarter.self) private var restarter
    let pullRequest: PullRequest
    @State private var isOpen = false

    var body: some View {
        if let state = pullRequest.ci {
            let failing = pullRequest.checks.filter { $0.state == .failure }.count
            Button {
                isOpen = true
            } label: {
                HStack(spacing: 2) {
                    CIStateIcon(state: state)
                    if failing > 0 { Text("\(failing)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the checks")
            .popover(isPresented: $isOpen, arrowEdge: .trailing) {
                ChecksPopover(pullRequest: pullRequest).environment(restarter)
            }
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

/// The checks of one pull request that did not pass, with a restart for each and the pull request's own switch.
struct ChecksPopover: View {
    @Environment(AutoRestarter.self) private var restarter
    @Environment(\.openURL) private var openURL
    let pullRequest: PullRequest

    var body: some View {
        let lines = restarter.lines(for: pullRequest)
        let open = lines.filter { $0.status != .passed }
        let passed = lines.count - open.count
        let restartable = lines.filter(\.canRestart).count

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Checks on \(String(pullRequest.headRefOid.prefix(7)))").font(.headline)
                Spacer()
                Text(lines.isEmpty ? "none reported" : "\(passed) of \(lines.count) passed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(open) { row($0) }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: open.count <= 8)
            Divider()
            Toggle("Auto-restart failed jobs of this pull request", isOn: Binding(
                get: { restarter.isEnabled(pullRequest) },
                set: { restarter.setEnabled(pullRequest, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack {
                Text("Up to \(restarter.limit) restart\(restarter.limit == 1 ? "" : "s") per job per commit")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if restartable > 1 {
                    Button("Restart \(restartable) failed") {
                        Task { await restarter.restartAllFailed(in: [pullRequest]) }
                    }
                    .controlSize(.small)
                }
            }
            if let error = restarter.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 440)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ line: AutoRestarter.Line) -> some View {
        HStack(spacing: 8) {
            Image(systemName: line.status.icon).foregroundStyle(line.status.color).frame(width: 16)
            Button {
                if let url = line.check.url { openURL(url) }
            } label: {
                Text(line.check.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(line.check.url == nil)
            .help(line.check.url?.absoluteString ?? "")
            Spacer(minLength: 8)
            Text(line.note(limit: restarter.limit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if line.canRestart {
                Button("Restart") {
                    Task { await restarter.restartNow(pullRequest, check: line.check.name) }
                }
                .controlSize(.small)
            }
        }
    }
}

extension AutoRestarter.Line {
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
        case .failed: return .red
        case .restarting, .running: return .orange
        case .gaveUp: return .purple
        case .passed: return .green
        case .unknown: return .secondary
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
