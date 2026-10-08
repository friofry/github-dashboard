import Charts
import DashboardCore
import SwiftUI

struct WeekChart: View {
    let stats: CodeStats?

    var body: some View {
        Chart(stats?.days ?? []) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Added", day.additions))
                .foregroundStyle(.green)
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Deleted", -day.deletions))
                .foregroundStyle(.red)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
            }
        }
        .overlay { if stats == nil { ProgressView() } }
    }
}

struct CodeView: View {
    let stats: CodeStats?
    let weekStart: Date

    var body: some View {
        if let stats {
            content(stats)
        } else {
            ProgressView("Counting this week's commits…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ stats: CodeStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("+\(stats.additions.formatted())").foregroundStyle(.green)
                        Text("−\(stats.deletions.formatted())").foregroundStyle(.red)
                    }
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("\(stats.commits) commits since \(weekStart.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout).foregroundStyle(.secondary)
                }

                GroupBox("By day") {
                    WeekChart(stats: stats).frame(height: 180).padding(.top, 6)
                }

                GroupBox("By repository") {
                    if stats.repos.isEmpty {
                        Text("No commits in pull requests this week")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(stats.repos) { row in
                                GridRow {
                                    Text(row.repo).lineLimit(1)
                                    Text("\(row.commits) commits").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    Text("+\(row.additions.formatted())").foregroundStyle(.green).gridColumnAlignment(.trailing)
                                    Text("−\(row.deletions.formatted())").foregroundStyle(.red).gridColumnAlignment(.trailing)
                                }
                            }
                        }
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }

                Text("Counts your non-merge commits in your pull requests updated this week. Direct pushes without a pull request are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                if stats.isPartial {
                    Label("You have more pull requests this week than are scanned, so the totals are a lower bound. Narrow the organizations in Settings for exact numbers.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
    }
}
