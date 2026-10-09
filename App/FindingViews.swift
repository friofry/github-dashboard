import DashboardCore
import SwiftUI

/// Right column: one finding, drawn rather than only described.
struct FindingDetail: View {
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let pullRequest: PullRequest
    let finding: Finding
    @Binding var selection: String?

    var body: some View {
        let diff = coordinator.diff(for: pullRequest)
        let link = coordinator.link(for: finding, in: pullRequest)
        let excerpt = diff?.excerpt(path: finding.path, from: finding.line, to: finding.endLine ?? finding.line) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Badge(text: finding.severity.rawValue, color: finding.severity.color)
                        Badge(text: finding.category.rawValue, color: .secondary)
                        Button {
                            if let link { openURL(link) }
                        } label: {
                            Label(location, systemImage: "arrow.up.right.square").font(.caption.monospaced()).lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        .tint(.blue)
                        .disabled(link == nil)
                        .help("Open this line on GitHub")
                    }
                    Text(finding.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                }

                if let impact = finding.impact { ImpactMeters(impact: impact) }
                Text(finding.problem).textSelection(.enabled)

                if let chain = finding.chain, chain.count > 1 { CauseChain(steps: chain) }
                if let scenario = finding.scenario, !scenario.rows.isEmpty {
                    ScenarioTable(scenario: scenario)
                } else if let example = finding.example, !example.isEmpty {
                    labelled("Example", example)
                }
                Label(finding.suggestion, systemImage: "wrench.and.screwdriver")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                if !excerpt.isEmpty {
                    CodeChange(path: finding.path, excerpt: excerpt, from: finding.line,
                               to: finding.endLine ?? finding.line,
                               replacement: CommentPart.suggestion(in: finding.comment))
                }

                CommentBox(coordinator: coordinator, pullRequest: pullRequest, finding: finding,
                           target: excerpt.filter { ($0.number ?? 0) >= finding.line && ($0.number ?? 0) <= (finding.endLine ?? finding.line) },
                           location: location)

                if let diff, !diff.files.isEmpty {
                    PullRequestMap(diff: diff, findings: coordinator.reviews[pullRequest.id]?.findings ?? [],
                                   current: finding, selection: $selection)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A different finding must not inherit the previous one's scroll position or draft.
        .id(finding.id)
    }

    private var location: String {
        let range = finding.endLine.map { $0 > finding.line ? "\(finding.line)-\($0)" : "\(finding.line)" } ?? "\(finding.line)"
        return "\(finding.path):\(range)"
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
    }
}

// MARK: - Impact (three scales)

struct ImpactMeters: View {
    let impact: Finding.Impact

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                meter("Harm", impact.harm, ["Minor", "Wrong result", "Severe"], impact.harmNote, .red)
                meter("How often", impact.likelihood, ["Rare case", "Normal use", "Every time"], impact.likelihoodNote, .orange)
                meter("Cost to fix", impact.effort, ["A line or two", "Small change", "Large change"], impact.effortNote, .blue)
            }
            Text("Claude's estimate").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func meter(_ title: String, _ value: Int, _ names: [String], _ note: String, _ color: Color) -> some View {
        let level = min(max(value, 1), 3)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...3, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 3).fill(step <= level ? color : Color.secondary.opacity(0.2)).frame(height: 6)
                }
            }
            Text(names[level - 1]).fontWeight(.semibold)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Cause and effect

struct CauseChain: View {
    let steps: [Finding.Step]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let isLast = index == steps.count - 1
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).fontWeight(.semibold)
                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(isLast ? Color.red.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isLast ? Color.red.opacity(0.6) : Color.secondary.opacity(0.3)))
                if !isLast {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 14)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

// MARK: - Scenario table

struct ScenarioTable: View {
    let scenario: Finding.Scenario

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scenario.title).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Now")
                    Text("After the fix")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(scenario.rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow(alignment: .top) {
                        Text(row.item).font(.callout.monospaced())
                        cell(row.now, row.nowOk)
                        cell(row.after, row.afterOk)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func cell(_ text: String, _ isOk: Bool) -> some View {
        Label(text, systemImage: isOk ? "checkmark" : "xmark")
            .foregroundStyle(isOk ? Color.green : .red)
            .fontWeight(.medium)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Code and the suggested change

struct CodeChange: View {
    let path: String
    let excerpt: [CodeLine]
    let from: Int
    let to: Int
    /// Lines that would replace `from...to`; nil when the comment suggests no concrete change.
    let replacement: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
            ForEach(Array(excerpt.enumerated()), id: \.offset) { _, line in
                let isTarget = (line.number ?? 0) >= from && (line.number ?? 0) <= to
                if isTarget, replacement != nil {
                    row(line.number, "−", line.text, .red)
                } else {
                    row(line.number, line.kind == .added ? "+" : " ", line.text, isTarget ? .yellow : nil)
                }
                if line.number == to, let replacement {
                    ForEach(Array(replacement.enumerated()), id: \.offset) { offset, text in
                        row(from + offset, "+", text, .green)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private func row(_ number: Int?, _ marker: String, _ text: String, _ tint: Color?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
            Text(marker).foregroundStyle(.secondary)
            Text(text.isEmpty ? " " : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(tint?.opacity(0.16) ?? .clear)
    }
}

// MARK: - The comment, as GitHub will show it

struct CommentBox: View {
    @Environment(\.openURL) private var openURL
    let coordinator: ReviewCoordinator
    let pullRequest: PullRequest
    let finding: Finding
    /// The lines the comment is attached to, for drawing a suggested change against them.
    let target: [CodeLine]
    let location: String
    @State private var showsMarkdown = false
    @State private var draft = ""
    @State private var confirmsPublish = false

    var body: some View {
        let key = ReviewCoordinator.key(finding, in: pullRequest)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comment to post").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $showsMarkdown) {
                    Text("As on GitHub").tag(false)
                    Text(finding.postedURL == nil ? "Edit" : "Markdown").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }

            if showsMarkdown {
                TextEditor(text: $draft)
                    .font(.callout.monospaced())
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(finding.postedURL != nil)
            } else {
                rendered
            }

            HStack {
                if let posted = finding.postedURL {
                    Button("Published", systemImage: "checkmark.circle.fill") { openURL(posted) }
                        .tint(.green).help("Open the comment on GitHub")
                } else if coordinator.publishing.contains(key) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Publish", systemImage: "paperplane") {
                        save()
                        confirmsPublish = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Copy", systemImage: "doc.on.doc") { copy(showsMarkdown ? draft : finding.comment) }
                if showsMarkdown, finding.postedURL == nil, draft != finding.comment {
                    Button("Save changes") { save() }
                    Button("Discard") { draft = finding.comment }
                }
            }
            if let error = coordinator.publishErrors[key] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { draft = finding.comment }
        // Posting is public and cannot be taken back from here, so it always asks first.
        .confirmationDialog("Publish this comment?", isPresented: $confirmsPublish) {
            Button("Publish to \(pullRequest.repository.nameWithOwner) #\(pullRequest.number)") {
                Task { await coordinator.publish(current, in: pullRequest) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be posted under your GitHub account on \(location).")
        }
    }

    /// The finding as stored now, including an edit saved a moment ago.
    private var current: Finding {
        coordinator.reviews[pullRequest.id]?.findings.first { $0.id == finding.id } ?? finding
    }

    private func save() {
        if draft != finding.comment { coordinator.setComment(draft, for: finding, in: pullRequest) }
    }

    private var rendered: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.blue)
                Text("You").fontWeight(.semibold)
                Text("on \(location)").foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(CommentPart.parse(finding.comment).enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text):
                        Text(inline(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    case .code("suggestion", let body):
                        suggestedChange(body.components(separatedBy: "\n"))
                    case .code(_, let body):
                        Text(body).font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private func suggestedChange(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggested change").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(Array(target.enumerated()), id: \.offset) { _, line in changeRow("−", line.text, .red) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in changeRow("+", line, .green) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func changeRow(_ marker: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker).foregroundStyle(.secondary)
            Text(text.isEmpty ? " " : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(tint.opacity(0.16))
    }

    private func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Where the finding sits in the pull request

struct PullRequestMap: View {
    let diff: ParsedDiff
    let findings: [Finding]
    let current: Finding
    @Binding var selection: String?
    private static let limit = 8

    var body: some View {
        // Files with findings first, then the most changed ones.
        let flagged = Set(findings.map(\.path))
        let ranked = diff.files.sorted {
            let lhs = (flagged.contains($0.path) ? 1 : 0, $0.added + $0.removed)
            let rhs = (flagged.contains($1.path) ? 1 : 0, $1.added + $1.removed)
            return lhs > rhs
        }
        let shown = Array(ranked.prefix(Self.limit))
        VStack(alignment: .leading, spacing: 6) {
            Text("Where it sits in the pull request").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(shown, id: \.path) { file in
                    GridRow {
                        Text(file.path.split(separator: "/").suffix(2).joined(separator: "/"))
                            .font(.caption.monospaced())
                            .fontWeight(file.path == current.path ? .semibold : .regular)
                            .foregroundStyle(file.path == current.path ? Color.blue : .primary)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(file.path)
                        track(file)
                        Text("+\(file.added) −\(file.removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if diff.files.count > shown.count {
                Text("and \(diff.files.count - shown.count) more files").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// A bar the length of the file as far as the diff shows it: green where lines were added, dots at findings.
    private func track(_ file: DiffFile) -> some View {
        let scale = CGFloat(max(file.lastLine, 1))
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 8)
                ForEach(Array(file.changedRanges.enumerated()), id: \.offset) { _, range in
                    Capsule().fill(Color.green.opacity(0.6))
                        .frame(width: max(3, CGFloat(range.count) / scale * width), height: 8)
                        .offset(x: CGFloat(range.lowerBound - 1) / scale * width)
                }
                ForEach(findings.filter { $0.path == file.path }) { finding in
                    Circle()
                        .fill(finding.id == current.id ? Color.blue : finding.severity.color)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: min(max(CGFloat(finding.line - 1) / scale * width - 7, 0), width - 14))
                        .onTapGesture { selection = finding.id }
                        .help(finding.title)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 120, minHeight: 16)
    }
}
