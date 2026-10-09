import DashboardCore
import SwiftUI

struct PullRequestList: View {
    @Environment(DashboardStore.self) private var store
    @Environment(AutoRestarter.self) private var restarter
    let pullRequests: [PullRequest]
    let showsAuthor: Bool
    @State private var filter: AutoRestarter.Filter?

    var body: some View {
        if pullRequests.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "checkmark.seal",
                                   description: Text("No open pull requests"))
        } else if showsAuthor {
            List(store.sorted(pullRequests)) { pullRequest in
                PullRequestRow(pullRequest: pullRequest, showsAuthor: true)
            }
        } else {
            // Only my own pull requests: restarting someone else's CI is theirs to decide.
            let shown = store.sorted(pullRequests).filter { pullRequest in
                filter.map { restarter.matches(pullRequest, $0) } ?? true
            }
            VStack(spacing: 0) {
                AutoRestartStrip(pullRequests: pullRequests, filter: $filter)
                List {
                    Section {
                        ForEach(shown) { PullRequestRow(pullRequest: $0, showsAuthor: false) }
                        if shown.isEmpty, let filter {
                            Text("No pull request has \(filter.title) checks.").foregroundStyle(.secondary)
                        }
                    }
                    JobsSection(pullRequests: pullRequests)
                }
            }
        }
    }
}

struct PullRequestRow: View {
    @Environment(DashboardStore.self) private var store
    @Environment(AutoRestarter.self) private var restarter
    @Environment(\.openURL) private var openURL
    let pullRequest: PullRequest
    let showsAuthor: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            link
            if showsAuthor {
                if let state = pullRequest.ci { CIStateIcon(state: state) }
            } else {
                ChecksButton(pullRequest: pullRequest)
            }
            Text("+\(pullRequest.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
            Text("−\(pullRequest.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var link: some View {
        let events = store.events(for: pullRequest)
        let newCount = events.filter(store.isNew).count
        let restarts = showsAuthor ? 0 : restarter.restarts(for: pullRequest)

        Button {
            if let url = store.visit(pullRequest) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(newCount > 0 ? Color.blue : .clear).frame(width: 8, height: 8).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pullRequest.title).fontWeight(newCount > 0 ? .semibold : .regular).lineLimit(1)
                        if pullRequest.isDraft { Badge(text: "Draft", color: .gray) }
                        decisionBadge
                    }
                    HStack(spacing: 6) {
                        Text("\(pullRequest.repository.nameWithOwner) #\(pullRequest.number)")
                        if showsAuthor, let author = pullRequest.author { Text("· @\(author.login)") }
                        Text("· \(pullRequest.updatedAt.formatted(.relative(presentation: .named)))")
                        if restarts > 0 {
                            Text("· CI restarted \(restarts)×").foregroundStyle(.orange)
                        }
                        // Said only where the pull request differs from the switch above the list.
                        if !showsAuthor, restarter.isEnabled(pullRequest) != restarter.restartAll {
                            Text(restarter.restartAll ? "· auto-restart paused" : "· auto-restart on")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if newCount > 0, let latest = events.first {
                        Text("\(newCount) new · @\(latest.actor) \(latest.summary)")
                            .font(.caption).foregroundStyle(.blue).lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var decisionBadge: some View {
        switch pullRequest.decision {
        case .approved: Badge(text: "Approved", color: .green)
        case .changesRequested: Badge(text: "Changes requested", color: .red)
        case nil: EmptyView()
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Updates

struct UpdatesView: View {
    let events: [PREvent]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView("All quiet", systemImage: "bell.slash",
                                   description: Text("No activity from other people in your open pull requests"))
        } else {
            List(events) { EventRow(event: $0) }
        }
    }
}

struct EventRow: View {
    @Environment(DashboardStore.self) private var store
    @Environment(\.openURL) private var openURL
    let event: PREvent

    var body: some View {
        let isNew = store.isNew(event)
        Button {
            if let url = store.visit(event.pullRequest, at: event.url) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.icon).foregroundStyle(isNew ? .blue : .secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(event.actor) ").fontWeight(.semibold) + Text(event.summary)
                    Text("\(event.pullRequest.repository.nameWithOwner) #\(event.pullRequest.number) · \(event.pullRequest.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer()
                Text(event.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(isNew ? 1 : 0.65)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension PREvent {
    var icon: String {
        switch kind {
        case .comment: return "text.bubble"
        case .approved: return "checkmark.seal"
        case .changesRequested: return "exclamationmark.bubble"
        case .reviewed: return "eye"
        case .commit: return "arrow.up.circle"
        }
    }

    /// What happened, phrased to follow the actor's name.
    var summary: String {
        let verb: String
        switch kind {
        case .comment: return text
        case .commit: return "pushed: \(text)"
        case .approved: verb = "approved"
        case .changesRequested: verb = "requested changes"
        case .reviewed: verb = "reviewed"
        }
        return text.isEmpty ? verb : "\(verb): \(text)"
    }
}
