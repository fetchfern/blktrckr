import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case invalidData(String)
    case invalidInterval
    case blockNotFound
    case overlap
    case continuationInFuture

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the local database: \(message)"
        case .execute(let message): "The local database could not be updated: \(message)"
        case .invalidData(let message): "The local database contains invalid data: \(message)"
        case .invalidInterval: "A time block must end after it starts."
        case .blockNotFound: "That time block no longer exists."
        case .overlap: "Time blocks cannot overlap."
        case .continuationInFuture: "A time block that extends into the future cannot be continued."
        }
    }
}

final class Database {
    private var connection: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL? = nil) throws {
        let databaseURL: URL
        if let url {
            databaseURL = url
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("BLKTRCKR", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseURL = directory.appendingPathComponent("TimeBlocks.sqlite")
        }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(connection)
            connection = nil
            throw DatabaseError.open(message)
        }
        sqlite3_busy_timeout(connection, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit { sqlite3_close(connection) }

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version")
        guard version <= 2 else {
            throw DatabaseError.invalidData("database schema version \(version) is newer than this app supports")
        }
        if version == 0 {
            try transaction {
                try execute("""
                    CREATE TABLE time_blocks (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                        started_at REAL NOT NULL,
                        ended_at REAL,
                        reminder_interval_seconds INTEGER,
                        next_reminder_at REAL,
                        confirmation_deadline REAL,
                        stop_reason TEXT CHECK (
                            stop_reason IS NULL OR stop_reason IN (
                                'manual', 'replacedByNewBlock', 'applicationQuit',
                                'reminderTimeout', 'systemSleep', 'manualEntry'
                            )
                        ),
                        was_timing_edited INTEGER NOT NULL DEFAULT 0,
                        description TEXT CHECK (description IS NULL OR length(trim(description)) > 0),
                        CHECK (ended_at IS NULL OR ended_at > started_at),
                        CHECK (reminder_interval_seconds IS NULL OR reminder_interval_seconds > 0),
                        CHECK (was_timing_edited IN (0, 1)),
                        CHECK (
                            (next_reminder_at IS NULL AND confirmation_deadline IS NULL)
                            OR (next_reminder_at IS NOT NULL AND confirmation_deadline IS NOT NULL)
                        ),
                        CHECK (
                            reminder_interval_seconds IS NOT NULL
                            OR (next_reminder_at IS NULL AND confirmation_deadline IS NULL)
                        ),
                        CHECK (
                            ended_at IS NULL
                            OR (next_reminder_at IS NULL AND confirmation_deadline IS NULL)
                        ),
                        CHECK (
                            (ended_at IS NULL AND stop_reason IS NULL)
                            OR (ended_at IS NOT NULL AND stop_reason IS NOT NULL)
                        )
                    )
                    """)
                try execute("CREATE INDEX time_blocks_started_at ON time_blocks(started_at)")
                try execute("CREATE UNIQUE INDEX time_blocks_one_active ON time_blocks((1)) WHERE ended_at IS NULL")
                try execute("""
                    CREATE TRIGGER time_blocks_no_overlap_insert
                    BEFORE INSERT ON time_blocks
                    WHEN EXISTS (
                        SELECT 1 FROM time_blocks existing
                        WHERE NEW.started_at < COALESCE(existing.ended_at, 1.0e100)
                          AND COALESCE(NEW.ended_at, 1.0e100) > existing.started_at
                    )
                    BEGIN SELECT RAISE(ABORT, 'time blocks overlap'); END
                    """)
                try execute("""
                    CREATE TRIGGER time_blocks_no_overlap_update
                    BEFORE UPDATE OF started_at, ended_at ON time_blocks
                    WHEN EXISTS (
                        SELECT 1 FROM time_blocks existing
                        WHERE existing.id <> NEW.id
                          AND NEW.started_at < COALESCE(existing.ended_at, 1.0e100)
                          AND COALESCE(NEW.ended_at, 1.0e100) > existing.started_at
                    )
                    BEGIN SELECT RAISE(ABORT, 'time blocks overlap'); END
                    """)
                try execute("PRAGMA user_version = 2")
            }
            return
        }

        if version == 1 {
            try transaction {
                try execute("""
                    ALTER TABLE time_blocks
                    ADD COLUMN description TEXT
                    CHECK (description IS NULL OR length(trim(description)) > 0)
                    """)
                try execute("PRAGMA user_version = 2")
            }
        }
    }

    func allBlocks() throws -> [TimeBlock] {
        try queryBlocks("SELECT * FROM time_blocks ORDER BY started_at")
    }

    func activeBlock() throws -> TimeBlock? {
        try queryBlocks("SELECT * FROM time_blocks WHERE ended_at IS NULL LIMIT 1").first
    }

    func block(id: UUID) throws -> TimeBlock? {
        try queryBlocks("SELECT * FROM time_blocks WHERE id = ? LIMIT 1") { statement in
            self.bind(id.uuidString, at: 1, in: statement)
        }.first
    }

    func blocks(intersecting interval: DateInterval) throws -> [TimeBlock] {
        try queryBlocks("""
            SELECT * FROM time_blocks
            WHERE started_at < ? AND COALESCE(ended_at, 1.0e100) > ?
            ORDER BY started_at
            """) { statement in
            sqlite3_bind_double(statement, 1, interval.end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        }
    }

    func nameUsages() throws -> [NameUsage] {
        let sql = """
            WITH grouped AS (
                SELECT lower(trim(name)) AS normalized_name,
                       COUNT(*) AS use_count,
                       MAX(started_at) AS most_recent
                FROM time_blocks
                GROUP BY lower(trim(name))
            )
            SELECT grouped.normalized_name,
                   recent.name,
                   grouped.use_count,
                   grouped.most_recent
            FROM grouped
            JOIN time_blocks recent
              ON lower(trim(recent.name)) = grouped.normalized_name
             AND recent.started_at = grouped.most_recent
            GROUP BY grouped.normalized_name
            """
        return try withStatement(sql) { statement in
            var result: [NameUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let normalized = text(statement, 0), let display = text(statement, 1) else {
                    throw DatabaseError.invalidData("a saved block has an unreadable name")
                }
                result.append(NameUsage(
                    normalizedName: normalized,
                    displayName: display,
                    count: Int(sqlite3_column_int64(statement, 2)),
                    mostRecentUse: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ))
            }
            return result
        }
    }

    @discardableResult
    func startBlock(
        name: String,
        description: String? = nil,
        reminderIntervalSeconds: Int?,
        at date: Date
    ) throws -> TimeBlock {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.invalidData("block names cannot be empty") }
        if let reminderIntervalSeconds, reminderIntervalSeconds <= 0 { throw DatabaseError.invalidData("invalid reminder interval") }

        let block = TimeBlock(
            id: UUID(), name: trimmed, description: BlockDescription.normalized(description),
            startedAt: date, endedAt: nil,
            reminderIntervalSeconds: reminderIntervalSeconds,
            nextReminderAt: nil, confirmationDeadline: nil,
            stopReason: nil, wasTimingEdited: false
        )
        try transaction {
            if let active = try activeBlock() {
                guard date > active.startedAt else { throw DatabaseError.invalidInterval }
                try completeStatement(id: active.id, at: date, reason: .replacedByNewBlock)
            }
            try insert(block)
        }
        return block
    }

    @discardableResult
    func completeBlock(id: UUID, at date: Date, reason: StopReason) throws -> TimeBlock {
        guard let existing = try block(id: id) else { throw DatabaseError.blockNotFound }
        if !existing.isActive { return existing }
        guard date > existing.startedAt else { throw DatabaseError.invalidInterval }
        try completeStatement(id: id, at: date, reason: reason)
        guard let completed = try block(id: id) else { throw DatabaseError.blockNotFound }
        return completed
    }

    func setReminder(id: UUID, reminderAt: Date, deadline: Date) throws {
        guard abs(deadline.timeIntervalSince(reminderAt) - 300) < 0.001 else {
            throw DatabaseError.invalidData("a reminder deadline must be five minutes after its reminder")
        }
        try update("""
            UPDATE time_blocks
            SET next_reminder_at = ?, confirmation_deadline = ?
            WHERE id = ? AND ended_at IS NULL AND reminder_interval_seconds IS NOT NULL
            """) { statement in
            sqlite3_bind_double(statement, 1, reminderAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, deadline.timeIntervalSince1970)
            bind(id.uuidString, at: 3, in: statement)
        }
    }

    func clearReminder(id: UUID) throws {
        try update("UPDATE time_blocks SET next_reminder_at = NULL, confirmation_deadline = NULL WHERE id = ?") {
            bind(id.uuidString, at: 1, in: $0)
        }
    }

    func renameBlock(id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.invalidData("block names cannot be empty") }
        try update("UPDATE time_blocks SET name = ? WHERE id = ? AND ended_at IS NOT NULL") { statement in
            bind(trimmed, at: 1, in: statement)
            bind(id.uuidString, at: 2, in: statement)
        }
    }

    func updateDescription(id: UUID, description: String?) throws {
        try update("UPDATE time_blocks SET description = ? WHERE id = ?") { statement in
            bind(BlockDescription.normalized(description), at: 1, in: statement)
            bind(id.uuidString, at: 2, in: statement)
        }
    }

    func updateTiming(id: UUID, start: Date, end: Date) throws {
        guard end > start else { throw DatabaseError.invalidInterval }
        try update("""
            UPDATE time_blocks
            SET started_at = ?, ended_at = ?, was_timing_edited = 1
            WHERE id = ? AND ended_at IS NOT NULL
            """) { statement in
            sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
            bind(id.uuidString, at: 3, in: statement)
        }
    }

    @discardableResult
    func continueBlock(id: UUID, at date: Date) throws -> TimeBlock {
        try transaction {
            guard let existing = try block(id: id) else { throw DatabaseError.blockNotFound }
            guard let endedAt = existing.endedAt else {
                throw DatabaseError.invalidData("only completed blocks can be continued")
            }
            guard existing.startedAt <= date, endedAt <= date else {
                throw DatabaseError.continuationInFuture
            }
            if try activeBlock() != nil { throw DatabaseError.overlap }

            try update("""
                UPDATE time_blocks
                SET ended_at = NULL, stop_reason = NULL,
                    next_reminder_at = NULL, confirmation_deadline = NULL
                WHERE id = ? AND ended_at IS NOT NULL
                """) { statement in
                bind(id.uuidString, at: 1, in: statement)
            }
            guard let continued = try block(id: id), continued.isActive else {
                throw DatabaseError.blockNotFound
            }
            return continued
        }
    }

    @discardableResult
    func createHistoricalBlock(
        name: String,
        description: String? = nil,
        start: Date,
        end: Date
    ) throws -> TimeBlock {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, end.timeIntervalSince(start) >= 300 else { throw DatabaseError.invalidInterval }
        let block = TimeBlock(
            id: UUID(), name: trimmed, description: BlockDescription.normalized(description),
            startedAt: start, endedAt: end,
            reminderIntervalSeconds: nil, nextReminderAt: nil, confirmationDeadline: nil,
            stopReason: .manualEntry, wasTimingEdited: false
        )
        try insert(block)
        return block
    }

    func deleteBlock(id: UUID) throws {
        try update("DELETE FROM time_blocks WHERE id = ? AND ended_at IS NOT NULL") {
            bind(id.uuidString, at: 1, in: $0)
        }
    }

    private func insert(_ block: TimeBlock) throws {
        try update("""
            INSERT INTO time_blocks (
                id, name, started_at, ended_at, reminder_interval_seconds,
                next_reminder_at, confirmation_deadline, stop_reason, was_timing_edited,
                description
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            bind(block.id.uuidString, at: 1, in: statement)
            bind(block.name, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, block.startedAt.timeIntervalSince1970)
            bind(block.endedAt, at: 4, in: statement)
            bind(block.reminderIntervalSeconds, at: 5, in: statement)
            bind(block.nextReminderAt, at: 6, in: statement)
            bind(block.confirmationDeadline, at: 7, in: statement)
            bind(block.stopReason?.rawValue, at: 8, in: statement)
            sqlite3_bind_int(statement, 9, block.wasTimingEdited ? 1 : 0)
            bind(block.description, at: 10, in: statement)
        }
    }

    private func completeStatement(id: UUID, at date: Date, reason: StopReason) throws {
        try update("""
            UPDATE time_blocks
            SET ended_at = ?, stop_reason = ?, next_reminder_at = NULL, confirmation_deadline = NULL
            WHERE id = ? AND ended_at IS NULL
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(reason.rawValue, at: 2, in: statement)
            bind(id.uuidString, at: 3, in: statement)
        }
    }

    private func queryBlocks(_ sql: String, bindValues: ((OpaquePointer) -> Void)? = nil) throws -> [TimeBlock] {
        try withStatement(sql) { statement in
            bindValues?(statement)
            var blocks: [TimeBlock] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteError() }
                blocks.append(try decodeBlock(statement))
            }
            return blocks
        }
    }

    private func decodeBlock(_ statement: OpaquePointer) throws -> TimeBlock {
        guard
            let idText = text(statement, 0), let id = UUID(uuidString: idText),
            let name = text(statement, 1)
        else { throw DatabaseError.invalidData("a saved block has malformed identity data") }

        let endedAt = optionalDate(statement, 3)
        let reasonText = text(statement, 7)
        let reason = reasonText.flatMap(StopReason.init(rawValue:))
        if reasonText != nil && reason == nil { throw DatabaseError.invalidData("a saved block has an unknown stop reason") }

        let block = TimeBlock(
            id: id,
            name: name,
            description: BlockDescription.normalized(text(statement, 9)),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            endedAt: endedAt,
            reminderIntervalSeconds: optionalInt(statement, 4),
            nextReminderAt: optionalDate(statement, 5),
            confirmationDeadline: optionalDate(statement, 6),
            stopReason: reason,
            wasTimingEdited: sqlite3_column_int(statement, 8) == 1
        )
        guard (block.endedAt == nil) == (block.stopReason == nil) else {
            throw DatabaseError.invalidData("a saved block violates active/completed state")
        }
        return block
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorPointer)
            throw DatabaseError.execute(message)
        }
    }

    private func update(_ sql: String, bindValues: (OpaquePointer) -> Void) throws {
        try withStatement(sql) { statement in
            bindValues(statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func sqliteError() -> DatabaseError {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        if message.contains("overlap") { return .overlap }
        return .execute(message)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Date?, at index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}
