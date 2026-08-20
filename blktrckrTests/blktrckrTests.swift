import XCTest
import SQLite3
@testable import blktrckr

final class blktrckrTests: XCTestCase {
    func testStartingNewBlockAtomicallyReplacesActiveBlock() throws {
        let database = try temporaryDatabase()
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let secondStart = firstStart.addingTimeInterval(20 * 60)

        let first = try database.startBlock(name: "Backend", reminderIntervalSeconds: 1_800, at: firstStart)
        try database.setReminder(
            id: first.id,
            reminderAt: firstStart.addingTimeInterval(1_800),
            deadline: firstStart.addingTimeInterval(2_100)
        )
        let second = try database.startBlock(name: "Meeting", reminderIntervalSeconds: nil, at: secondStart)

        let blocks = try database.allBlocks()
        let completedFirst = try XCTUnwrap(blocks.first(where: { $0.id == first.id }))
        XCTAssertEqual(completedFirst.endedAt, secondStart)
        XCTAssertEqual(completedFirst.stopReason, .replacedByNewBlock)
        XCTAssertNil(completedFirst.nextReminderAt)
        XCTAssertNil(completedFirst.confirmationDeadline)
        XCTAssertEqual(try database.activeBlock()?.id, second.id)
    }

    func testDatabaseRejectsOverlappingHistoricalBlocks() throws {
        let database = try temporaryDatabase()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try database.createHistoricalBlock(
            name: "First",
            start: start,
            end: start.addingTimeInterval(60 * 60)
        )

        XCTAssertThrowsError(
            try database.createHistoricalBlock(
                name: "Overlap",
                start: start.addingTimeInterval(30 * 60),
                end: start.addingTimeInterval(90 * 60)
            )
        ) { error in
            guard case DatabaseError.overlap = error else {
                return XCTFail("Expected overlap error, got \(error)")
            }
        }
    }

    func testCompletingBlockClearsReminderStateAndPreservesReasonWhenEdited() throws {
        let database = try temporaryDatabase()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let block = try database.startBlock(name: "Database", reminderIntervalSeconds: 900, at: start)
        try database.setReminder(
            id: block.id,
            reminderAt: start.addingTimeInterval(900),
            deadline: start.addingTimeInterval(1_200)
        )
        _ = try database.completeBlock(id: block.id, at: start.addingTimeInterval(1_200), reason: .reminderTimeout)
        try database.updateTiming(
            id: block.id,
            start: start.addingTimeInterval(5 * 60),
            end: start.addingTimeInterval(25 * 60)
        )

        let saved = try XCTUnwrap(database.block(id: block.id))
        XCTAssertNil(saved.nextReminderAt)
        XCTAssertNil(saved.confirmationDeadline)
        XCTAssertEqual(saved.stopReason, .reminderTimeout)
        XCTAssertTrue(saved.wasTimingEdited)
        XCTAssertEqual(saved.stopLabel, "Originally stopped after reminder timeout")
    }

    func testDescriptionsRoundTripUpdateAndNormalizeEmptyValues() throws {
        let database = try temporaryDatabase()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let block = try database.startBlock(
            name: "Backend",
            description: "  Fix notification timing  ",
            reminderIntervalSeconds: nil,
            at: start
        )

        XCTAssertEqual(try database.block(id: block.id)?.description, "Fix notification timing")

        try database.updateDescription(id: block.id, description: "  Investigate retries  ")
        XCTAssertEqual(try database.block(id: block.id)?.description, "Investigate retries")

        try database.updateDescription(id: block.id, description: "  \n ")
        XCTAssertNil(try database.block(id: block.id)?.description)
    }

    func testVersionOneDatabaseMigratesDescriptionsWithoutReplacingRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blktrckrMigrationTests-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let oldSchema = """
            CREATE TABLE time_blocks (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                reminder_interval_seconds INTEGER,
                next_reminder_at REAL,
                confirmation_deadline REAL,
                stop_reason TEXT,
                was_timing_edited INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO time_blocks (
                id, name, started_at, ended_at, stop_reason, was_timing_edited
            ) VALUES (
                '00000000-0000-0000-0000-000000000001', 'Existing', 1000, 2000, 'manual', 0
            );
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(connection, oldSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let database = try Database(url: url)
        let existingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(try database.block(id: existingID)?.name, "Existing")
        XCTAssertNil(try database.block(id: existingID)?.description)

        try database.updateDescription(id: existingID, description: "Migrated description")
        XCTAssertEqual(try database.block(id: existingID)?.description, "Migrated description")
    }

    func testAutocompleteRanksByCountThenRecencyThenAlphabetically() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let usages = [
            NameUsage(normalizedName: "postgres cleanup", displayName: "Postgres Cleanup", count: 2, mostRecentUse: base),
            NameUsage(normalizedName: "postgres debugging", displayName: "PostgreSQL Debugging", count: 3, mostRecentUse: base.addingTimeInterval(-100)),
            NameUsage(normalizedName: "postmortem", displayName: "Postmortem", count: 1, mostRecentUse: base.addingTimeInterval(100))
        ]

        XCTAssertEqual(NameCompletion.suggestion(for: "post", usages: usages), "PostgreSQL Debugging")
        XCTAssertNil(NameCompletion.suggestion(for: "unmatched", usages: usages))
    }

    func testDailyIntersectionSplitsCrossMidnightBlock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 23, minute: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 0, minute: 30)))
        let block = TimeBlock(
            id: UUID(), name: "Late work", startedAt: start, endedAt: end,
            reminderIntervalSeconds: nil, nextReminderAt: nil, confirmationDeadline: nil,
            stopReason: .manual, wasTimingEdited: false
        )

        let firstDay = calendar.dayInterval(containing: start)
        let secondDay = calendar.dayInterval(containing: end)
        XCTAssertEqual(block.intersection(with: firstDay, now: end)?.duration, 30 * 60)
        XCTAssertEqual(block.intersection(with: secondDay, now: end)?.duration, 30 * 60)
    }

    func testSecondReminderCopyUsesTotalElapsedTime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let block = TimeBlock(
            id: UUID(), name: "Focus", startedAt: start, endedAt: nil,
            reminderIntervalSeconds: 30 * 60, nextReminderAt: nil, confirmationDeadline: nil,
            stopReason: nil, wasTimingEdited: false
        )

        XCTAssertEqual(
            NotificationCopy.reminderBody(for: block, at: start.addingTimeInterval(60 * 60)),
            "Focus has been running for 1h."
        )
    }

    func testMovingBlockCanSnapAcrossAnotherBlock() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let moving = completedBlock(
            name: "Moving",
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let obstacle = completedBlock(
            name: "Obstacle",
            start: base.addingTimeInterval(60 * 60),
            end: base.addingTimeInterval(120 * 60)
        )

        let nearSide = TimelineMoveResolver.nearestAvailableInterval(
            for: moving,
            proposedStart: base.addingTimeInterval(50 * 60),
            among: [obstacle]
        )
        XCTAssertEqual(nearSide.start, base.addingTimeInterval(30 * 60))

        let farSide = TimelineMoveResolver.nearestAvailableInterval(
            for: moving,
            proposedStart: base.addingTimeInterval(80 * 60),
            among: [obstacle]
        )
        XCTAssertEqual(farSide.start, base.addingTimeInterval(120 * 60))
        XCTAssertEqual(farSide.duration, 30 * 60)
    }

    func testMovingBlockCanSnapAcrossAnotherBlockTowardEarlierTime() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let obstacle = completedBlock(
            name: "Obstacle",
            start: base.addingTimeInterval(60 * 60),
            end: base.addingTimeInterval(120 * 60)
        )
        let moving = completedBlock(
            name: "Moving",
            start: base.addingTimeInterval(150 * 60),
            end: base.addingTimeInterval(180 * 60)
        )

        let farSide = TimelineMoveResolver.nearestAvailableInterval(
            for: moving,
            proposedStart: base.addingTimeInterval(65 * 60),
            among: [obstacle]
        )
        XCTAssertEqual(farSide.start, base.addingTimeInterval(30 * 60))
        XCTAssertEqual(farSide.duration, 30 * 60)
    }

    func testContinuingBlockReopensOriginalInterval() throws {
        let database = try temporaryDatabase()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try database.startBlock(name: "Focus", reminderIntervalSeconds: 1_800, at: start)
        _ = try database.completeBlock(
            id: original.id,
            at: start.addingTimeInterval(45 * 60),
            reason: .applicationQuit
        )

        let continued = try database.continueBlock(
            id: original.id,
            at: start.addingTimeInterval(60 * 60)
        )

        XCTAssertEqual(continued.id, original.id)
        XCTAssertEqual(continued.startedAt, start)
        XCTAssertNil(continued.endedAt)
        XCTAssertNil(continued.stopReason)
        XCTAssertEqual(continued.reminderIntervalSeconds, 1_800)
        XCTAssertEqual(try database.activeBlock()?.id, original.id)
    }

    func testContinuingBlockRejectsFutureAndOverlap() throws {
        let database = try temporaryDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = try database.createHistoricalBlock(
            name: "Past",
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: now.addingTimeInterval(-90 * 60)
        )
        _ = try database.createHistoricalBlock(
            name: "Later",
            start: now.addingTimeInterval(-60 * 60),
            end: now.addingTimeInterval(-30 * 60)
        )

        XCTAssertThrowsError(try database.continueBlock(id: past.id, at: now)) { error in
            guard case DatabaseError.overlap = error else {
                return XCTFail("Expected overlap error, got \(error)")
            }
        }

        let future = try database.createHistoricalBlock(
            name: "Future",
            start: now.addingTimeInterval(60 * 60),
            end: now.addingTimeInterval(90 * 60)
        )
        XCTAssertThrowsError(try database.continueBlock(id: future.id, at: now)) { error in
            guard case DatabaseError.continuationInFuture = error else {
                return XCTFail("Expected future-block error, got \(error)")
            }
        }
    }

    func testContinuingBlockTrimsEndWhenOverlappingNow() throws {
        let database = try temporaryDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overlapping = try database.createHistoricalBlock(
            name: "Overlapping",
            start: now.addingTimeInterval(-30 * 60),
            end: now.addingTimeInterval(30 * 60)
        )

        let continued = try database.continueBlock(id: overlapping.id, at: now)

        XCTAssertEqual(continued.id, overlapping.id)
        XCTAssertEqual(continued.startedAt, overlapping.startedAt)
        XCTAssertNil(continued.endedAt)
        XCTAssertTrue(continued.wasTimingEdited)
        XCTAssertEqual(try database.activeBlock()?.id, overlapping.id)
    }

    func testSummariesUseLocalDayWeekAndHourBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        func date(day: Int, hour: Int, minute: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: day,
                hour: hour,
                minute: minute
            )))
        }

        let now = try date(day: 18, hour: 10)
        let blocks = [
            completedBlock(
                name: "Across midnight",
                start: try date(day: 16, hour: 23, minute: 30),
                end: try date(day: 17, hour: 0, minute: 30)
            ),
            completedBlock(
                name: "Monday",
                start: try date(day: 17, hour: 9),
                end: try date(day: 17, hour: 11)
            ),
            TimeBlock(
                id: UUID(), name: "Active", startedAt: try date(day: 18, hour: 8, minute: 30), endedAt: nil,
                reminderIntervalSeconds: nil, nextReminderAt: nil, confirmationDeadline: nil,
                stopReason: nil, wasTimingEdited: false
            ),
            completedBlock(
                name: "Future entry",
                start: try date(day: 18, hour: 15),
                end: try date(day: 18, hour: 16)
            )
        ]

        let summary = SummariesSnapshot.calculate(blocks: blocks, now: now, calendar: calendar)

        XCTAssertEqual(summary.dailyTotals.count, 14)
        XCTAssertEqual(summary.weeklyTotals.count, 6)
        XCTAssertEqual(summary.heatmapCells.count, 14 * 24)
        XCTAssertEqual(summary.thisWeekTotal, 4 * 60 * 60, accuracy: 0.001)

        let sunday = try date(day: 16, hour: 12)
        let monday = try date(day: 17, hour: 12)
        let tuesday = try date(day: 18, hour: 9)
        XCTAssertEqual(
            summary.dailyTotals.first(where: { calendar.isDate($0.start, inSameDayAs: sunday) })?.duration,
            30 * 60
        )
        XCTAssertEqual(
            summary.dailyTotals.first(where: { calendar.isDate($0.start, inSameDayAs: monday) })?.duration,
            2.5 * 60 * 60
        )
        XCTAssertEqual(
            summary.dailyTotals.first(where: { calendar.isDate($0.start, inSameDayAs: tuesday) })?.duration,
            1.5 * 60 * 60
        )

        XCTAssertEqual(heatmapDuration(in: summary, on: sunday, hour: 23, calendar: calendar), 30 * 60)
        XCTAssertEqual(heatmapDuration(in: summary, on: monday, hour: 0, calendar: calendar), 30 * 60)
        XCTAssertEqual(heatmapDuration(in: summary, on: monday, hour: 9, calendar: calendar), 60 * 60)
        XCTAssertEqual(heatmapDuration(in: summary, on: tuesday, hour: 8, calendar: calendar), 30 * 60)
        XCTAssertEqual(heatmapDuration(in: summary, on: tuesday, hour: 9, calendar: calendar), 60 * 60)
        XCTAssertEqual(heatmapDuration(in: summary, on: tuesday, hour: 15, calendar: calendar), 0)
    }

    func testSummaryHeatmapAggregatesRepeatedDaylightSavingHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-11-01T05:00:00Z"))
        let end = try XCTUnwrap(formatter.date(from: "2026-11-01T07:00:00Z"))
        let now = end.addingTimeInterval(60 * 60)
        let block = completedBlock(name: "Repeated hour", start: start, end: end)

        let summary = SummariesSnapshot.calculate(blocks: [block], now: now, calendar: calendar)

        XCTAssertEqual(
            heatmapDuration(in: summary, on: start, hour: 1, calendar: calendar),
            2 * 60 * 60
        )
    }

    @MainActor
    func testEventAppearanceMappingsPersistByNormalizedName() throws {
        let suiteName = "blktrckrTests.EventAppearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "appearance-test"
        let color = EventColor(red: 0.12, green: 0.34, blue: 0.56)

        let store = EventAppearanceStore(defaults: defaults, storageKey: key)
        store.register(name: "  Backend  ")
        store.setColor(color, for: "BACKEND")
        store.setIcon("terminal.fill", for: "backend")

        XCTAssertEqual(store.colorOverride(for: " Backend "), color)
        XCTAssertEqual(store.icon(for: "BACKEND"), "terminal.fill")
        XCTAssertTrue(store.hasOverrides(for: "backend"))
        XCTAssertEqual(BlockPalette.color(for: "Backend"), BlockPalette.color(for: " backend "))

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var first = completedBlock(name: "Backend", start: start, end: start.addingTimeInterval(300))
        var second = completedBlock(
            name: "Backend",
            start: start.addingTimeInterval(300),
            end: start.addingTimeInterval(600)
        )
        first.description = "First description"
        second.description = "Completely different description"
        XCTAssertEqual(store.eventNames(from: [first, second]), ["Backend"])

        let reloaded = EventAppearanceStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(reloaded.colorOverride(for: "backend"), color)
        XCTAssertEqual(reloaded.icon(for: " backend "), "terminal.fill")

        XCTAssertTrue(reloaded.hasAppearanceEntry(for: "backend"))
        reloaded.deleteOverride(for: "BACKEND")
        XCTAssertNil(reloaded.colorOverride(for: "backend"))
        XCTAssertNil(reloaded.icon(for: "backend"))
        XCTAssertFalse(reloaded.hasAppearanceEntry(for: "backend"))
    }

    private func temporaryDatabase() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blktrckrTests-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        return try Database(url: url)
    }

    private func completedBlock(name: String, start: Date, end: Date) -> TimeBlock {
        TimeBlock(
            id: UUID(), name: name, startedAt: start, endedAt: end,
            reminderIntervalSeconds: nil, nextReminderAt: nil, confirmationDeadline: nil,
            stopReason: .manualEntry, wasTimingEdited: false
        )
    }

    private func heatmapDuration(
        in summary: SummariesSnapshot,
        on date: Date,
        hour: Int,
        calendar: Calendar
    ) -> TimeInterval? {
        summary.heatmapCells.first {
            $0.hour == hour && calendar.isDate($0.dayStart, inSameDayAs: date)
        }?.duration
    }
}
