import Foundation

struct SummaryPeriod: Identifiable, Equatable {
    let start: Date
    let end: Date
    let duration: TimeInterval

    var id: Date { start }
    var hours: Double { duration / 3_600 }
}

struct SummaryHeatmapCell: Identifiable, Equatable {
    struct ID: Hashable {
        let dayStart: Date
        let hour: Int
    }

    let dayStart: Date
    let dayEnd: Date
    let hour: Int
    let duration: TimeInterval

    var id: ID { ID(dayStart: dayStart, hour: hour) }
    var plotStart: Int { 23 - hour }
    var plotEnd: Int { 24 - hour }
}

struct SummariesSnapshot: Equatable {
    let currentWeek: DateInterval
    let thisWeekTotal: TimeInterval
    let dailyTotals: [SummaryPeriod]
    let weeklyTotals: [SummaryPeriod]
    let heatmapCells: [SummaryHeatmapCell]

    var maximumDailyHours: Double {
        dailyTotals.map(\.hours).max() ?? 0
    }

    var maximumWeeklyHours: Double {
        weeklyTotals.map(\.hours).max() ?? 0
    }

    var maximumHeatmapDuration: TimeInterval {
        heatmapCells.map(\.duration).max() ?? 0
    }

    static func calculate(
        blocks: [TimeBlock],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SummariesSnapshot {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let dailyTotals = periods(
            count: 14,
            startingAt: firstDay,
            component: .day,
            blocks: blocks,
            now: now,
            calendar: calendar
        )

        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: today, end: calendar.date(byAdding: .day, value: 7, to: today) ?? now)
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -5, to: currentWeek.start)
            ?? currentWeek.start
        let weeklyTotals = periods(
            count: 6,
            startingAt: firstWeek,
            component: .weekOfYear,
            blocks: blocks,
            now: now,
            calendar: calendar
        )

        return SummariesSnapshot(
            currentWeek: currentWeek,
            thisWeekTotal: total(in: currentWeek, blocks: blocks, now: now),
            dailyTotals: dailyTotals,
            weeklyTotals: weeklyTotals,
            heatmapCells: heatmap(
                blocks: blocks,
                now: now,
                days: dailyTotals,
                calendar: calendar
            )
        )
    }

    private static func periods(
        count: Int,
        startingAt firstStart: Date,
        component: Calendar.Component,
        blocks: [TimeBlock],
        now: Date,
        calendar: Calendar
    ) -> [SummaryPeriod] {
        (0..<count).compactMap { offset in
            guard let start = calendar.date(byAdding: component, value: offset, to: firstStart),
                  let end = calendar.date(byAdding: component, value: offset + 1, to: firstStart) else {
                return nil
            }
            let interval = DateInterval(start: start, end: end)
            return SummaryPeriod(
                start: start,
                end: end,
                duration: total(in: interval, blocks: blocks, now: now)
            )
        }
    }

    private static func total(
        in interval: DateInterval,
        blocks: [TimeBlock],
        now: Date
    ) -> TimeInterval {
        blocks.reduce(0) { result, block in
            let start = max(interval.start, block.startedAt)
            let end = min(interval.end, block.effectiveEnd(now: now), now)
            return result + max(0, end.timeIntervalSince(start))
        }
    }

    private static func heatmap(
        blocks: [TimeBlock],
        now: Date,
        days: [SummaryPeriod],
        calendar: Calendar
    ) -> [SummaryHeatmapCell] {
        guard let rangeStart = days.first?.start, let rangeEnd = days.last?.end else { return [] }
        var durations: [SummaryHeatmapCell.ID: TimeInterval] = [:]

        for block in blocks {
            var cursor = max(block.startedAt, rangeStart)
            let blockEnd = min(block.effectiveEnd(now: now), now, rangeEnd)

            while cursor < blockEnd {
                guard let hourInterval = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let segmentEnd = min(hourInterval.end, blockEnd)
                guard segmentEnd > cursor else { break }

                let dayStart = calendar.startOfDay(for: cursor)
                let hour = calendar.component(.hour, from: cursor)
                let id = SummaryHeatmapCell.ID(dayStart: dayStart, hour: hour)
                durations[id, default: 0] += segmentEnd.timeIntervalSince(cursor)
                cursor = segmentEnd
            }
        }

        return days.flatMap { day in
            (0..<24).map { hour in
                let id = SummaryHeatmapCell.ID(dayStart: day.start, hour: hour)
                return SummaryHeatmapCell(
                    dayStart: day.start,
                    dayEnd: day.end,
                    hour: hour,
                    duration: durations[id, default: 0]
                )
            }
        }
    }
}
