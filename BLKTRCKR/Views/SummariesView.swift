import Charts
import SwiftUI

struct SummariesView: View {
    @EnvironmentObject private var state: AppState
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let snapshot = SummariesSnapshot.calculate(blocks: state.blocks, now: state.now, calendar: calendar)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                thisWeek(snapshot)
                dailyChart(snapshot)
                weeklyChart(snapshot)
                heatmap(snapshot)
            }
            .padding(24)
        }
        .navigationTitle("Summaries")
    }

    private func thisWeek(_ snapshot: SummariesSnapshot) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Total time worked this week")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(TimeText.duration(snapshot.thisWeekTotal))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                Text(weekRange(snapshot.currentWeek))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .summarySectionBackground()
    }

    private func dailyChart(_ snapshot: SummariesSnapshot) -> some View {
        summarySection(title: "Last 14 days", subtitle: "Total time worked each day") {
            Chart(snapshot.dailyTotals) { day in
                BarMark(
                    x: .value("Day", day.start, unit: .day),
                    y: .value("Hours", day.hours)
                )
                .foregroundStyle(.tint)
                .cornerRadius(4)
                .accessibilityLabel(day.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityValue(TimeText.duration(day.duration))
            }
            .chartYScale(domain: 0...max(1, snapshot.maximumDailyHours * 1.12))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours.formatted(.number.precision(.fractionLength(0...1))) + "h")
                        }
                    }
                }
            }
            .frame(height: 190)
        }
    }

    private func weeklyChart(_ snapshot: SummariesSnapshot) -> some View {
        summarySection(title: "Last 6 weeks", subtitle: "Total time worked each calendar week") {
            Chart(snapshot.weeklyTotals) { week in
                BarMark(
                    x: .value("Week", week.start, unit: .weekOfYear),
                    y: .value("Hours", week.hours)
                )
                .foregroundStyle(.tint)
                .cornerRadius(4)
                .accessibilityLabel("Week of \(week.start.formatted(.dateTime.month(.wide).day()))")
                .accessibilityValue(TimeText.duration(week.duration))
            }
            .chartYScale(domain: 0...max(1, snapshot.maximumWeeklyHours * 1.12))
            .chartXAxis {
                AxisMarks(values: snapshot.weeklyTotals.map(\.start)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours.formatted(.number.precision(.fractionLength(0...1))) + "h")
                        }
                    }
                }
            }
            .frame(height: 190)
        }
    }

    private func heatmap(_ snapshot: SummariesSnapshot) -> some View {
        summarySection(title: "Busiest hours", subtitle: "Time worked within each hour over the last 14 days") {
            Chart(snapshot.heatmapCells) { cell in
                RectangleMark(
                    xStart: .value("Day start", cell.dayStart),
                    xEnd: .value("Day end", cell.dayEnd),
                    yStart: .value("Hour start", cell.plotStart),
                    yEnd: .value("Hour end", cell.plotEnd)
                )
                .foregroundStyle(heatmapColor(for: cell.duration, maximum: snapshot.maximumHeatmapDuration))
                .accessibilityLabel(
                    "\(cell.dayStart.formatted(.dateTime.weekday(.wide).month(.wide).day())), \(hourLabel(cell.hour))"
                )
                .accessibilityValue(TimeText.duration(cell.duration))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [3, 6, 9, 12, 15, 18, 21, 24]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel {
                        if let plotValue = value.as(Int.self) {
                            Text(hourLabel(24 - plotValue))
                        }
                    }
                }
            }
            .chartYScale(domain: 0...24)
            .frame(height: 340)

            HStack(spacing: 8) {
                Text("0m")
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.08), Color.accentColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 110, height: 8)
                .clipShape(Capsule())
                Text(TimeText.duration(snapshot.maximumHeatmapDuration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func summarySection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .summarySectionBackground()
    }

    private func heatmapColor(for duration: TimeInterval, maximum: TimeInterval) -> Color {
        guard maximum > 0 else { return Color.accentColor.opacity(0.08) }
        let intensity = duration / maximum
        return Color.accentColor.opacity(0.08 + (0.92 * intensity))
    }

    private func weekRange(_ interval: DateInterval) -> String {
        let finalDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(finalDay.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        if normalized == 0 { return "12 AM" }
        if normalized < 12 { return "\(normalized) AM" }
        if normalized == 12 { return "12 PM" }
        return "\(normalized - 12) PM"
    }
}

private extension View {
    func summarySectionBackground() -> some View {
        padding(18)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}
