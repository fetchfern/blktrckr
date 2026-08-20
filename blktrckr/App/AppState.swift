import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let openTimeBlocksWindow = Notification.Name("openTimeBlocksWindow")
}

struct AppWarning: Identifiable, Equatable {
    enum Kind: String { case database, notifications, scheduling, action }
    let kind: Kind
    let message: String
    var id: String { kind.rawValue }
}

enum TimelineEditMode {
    case start
    case end
    case move
}

enum StartBlockOutcome: Equatable {
    case started
    case failed(String)
}

enum TimelineMoveResolver {
    static func nearestAvailableInterval(
        for block: TimeBlock,
        proposedStart: Date,
        among otherBlocks: [TimeBlock]
    ) -> DateInterval {
        guard let originalEnd = block.endedAt else {
            return DateInterval(start: block.startedAt, end: block.startedAt)
        }

        let duration = originalEnd.timeIntervalSince(block.startedAt)
        let proposed = DateInterval(start: proposedStart, duration: duration)
        if isAvailable(proposed, among: otherBlocks) {
            return proposed
        }

        var candidateStarts = [block.startedAt]
        for other in otherBlocks {
            candidateStarts.append(other.startedAt.addingTimeInterval(-duration))
            if let end = other.endedAt {
                candidateStarts.append(end)
            }
        }

        let validStarts = candidateStarts.filter { candidateStart in
            isAvailable(
                DateInterval(start: candidateStart, duration: duration),
                among: otherBlocks
            )
        }

        let movingEarlier = proposedStart < block.startedAt
        let bestStart = validStarts.min { lhs, rhs in
            let lhsDistance = abs(lhs.timeIntervalSince(proposedStart))
            let rhsDistance = abs(rhs.timeIntervalSince(proposedStart))
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance < rhsDistance
            }
            return movingEarlier ? lhs < rhs : lhs > rhs
        } ?? block.startedAt

        return DateInterval(start: bestStart, duration: duration)
    }

    private static func isAvailable(_ interval: DateInterval, among blocks: [TimeBlock]) -> Bool {
        !blocks.contains { other in
            let otherEnd = other.endedAt ?? .distantFuture
            return interval.start < otherEnd && interval.end > other.startedAt
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var blocks: [TimeBlock] = []
    @Published var selectedDate = Date()
    @Published var selectedBlockID: UUID?
    @Published var isStartPresented = false
    @Published private(set) var warnings: [AppWarning] = []
    @Published private(set) var now = Date()

    let launchAtLogin = LaunchAtLoginController()
    let eventAppearances = EventAppearanceStore()
    private let notifications = NotificationManager.shared
    private var database: Database?
    private var ticker: Timer?
    private var deadlineTask: Task<Void, Never>?
    private var hasPreparedForTermination = false

    private init() {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            let testURL = isRunningTests
                ? FileManager.default.temporaryDirectory.appendingPathComponent("blktrckr-TestHost-\(UUID().uuidString).sqlite")
                : nil
            database = try Database(url: testURL)
            refresh()
        } catch {
            setWarning(.database, error.localizedDescription)
            NSLog("Database initialization failed: %@", error.localizedDescription)
        }

        if !isRunningTests {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
            Task { await bootstrap() }
        }
    }

    deinit {
        ticker?.invalidate()
        deadlineTask?.cancel()
    }

    var activeBlock: TimeBlock? { blocks.first(where: \.isActive) }
    var selectedBlock: TimeBlock? { blocks.first(where: { $0.id == selectedBlockID }) }

    var nameUsages: [NameUsage] {
        guard let database else { return [] }
        do { return try database.nameUsages() }
        catch { handle(error); return [] }
    }

    func presentStart() { isStartPresented = true }

    func startBlock(
        name: String,
        description: String? = nil,
        reminder: ReminderChoice
    ) -> StartBlockOutcome {
        guard let database else {
            return .failed("The local database is unavailable.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Enter a name for the time block.") }
        let replacedID = activeBlock?.id
        do {
            let block = try database.startBlock(
                name: trimmed,
                description: description,
                reminderIntervalSeconds: reminder.seconds,
                at: Date()
            )
            if let replacedID { notifications.cancelReminder(for: replacedID) }
            refresh()
            selectedDate = block.startedAt
            selectedBlockID = block.id
            isStartPresented = false
            if reminder.seconds != nil {
                Task { await scheduleNextReminder(for: block.id, relativeTo: block.startedAt) }
            }
            return .started
        } catch {
            NSLog("Could not start time block: %@", error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    func stopActiveManually() {
        guard let activeBlock else { return }
        stop(blockID: activeBlock.id, at: Date(), reason: .manual, notify: false)
    }

    func renameSelected(to name: String) -> Bool {
        guard let database, let block = selectedBlock, !block.isActive else { return false }
        do {
            try database.renameBlock(id: block.id, name: name)
            refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func updateSelectedDescription(_ description: String?) -> Bool {
        guard let database, let block = selectedBlock else { return false }
        do {
            try database.updateDescription(id: block.id, description: description)
            refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func deleteSelected() {
        guard let database, let block = selectedBlock, !block.isActive else { return }
        do {
            try database.deleteBlock(id: block.id)
            selectedBlockID = nil
            refresh()
        } catch { handle(error) }
    }

    func continueBlock(id: UUID) {
        guard let database else { return }
        let continuedAt = Date()
        do {
            let block = try database.continueBlock(id: id, at: continuedAt)
            removeWarning(.action)
            refresh()
            selectedDate = continuedAt
            selectedBlockID = block.id
            if block.reminderIntervalSeconds != nil {
                Task { await scheduleNextReminder(for: block.id, relativeTo: continuedAt) }
            }
        } catch DatabaseError.continuationInFuture {
            setWarning(.action, "This block can’t be continued because it extends into the future.")
        } catch DatabaseError.overlap {
            setWarning(.action, "This block can’t be continued because doing so would overlap another time block.")
        } catch {
            setWarning(.action, "This block couldn’t be continued: \(error.localizedDescription)")
        }
    }

    func dismissWarning(_ kind: AppWarning.Kind) {
        removeWarning(kind)
    }

    func createHistorical(
        name: String,
        description: String? = nil,
        start: Date,
        end: Date
    ) -> Bool {
        guard let database else { return false }
        do {
            let block = try database.createHistoricalBlock(
                name: name,
                description: description,
                start: start,
                end: end
            )
            refresh()
            selectedBlockID = block.id
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func updateTiming(id: UUID, start: Date, end: Date) {
        guard let database else { return }
        do {
            try database.updateTiming(id: id, start: start, end: end)
            refresh()
        } catch { handle(error) }
    }

    func blocksForSelectedDay(calendar: Calendar = .autoupdatingCurrent) -> [TimeBlock] {
        let day = calendar.dayInterval(containing: selectedDate)
        return blocks.filter { $0.startedAt < day.end && $0.effectiveEnd(now: now) > day.start }
    }

    func totalForSelectedDay(calendar: Calendar = .autoupdatingCurrent) -> TimeInterval {
        let day = calendar.dayInterval(containing: selectedDate)
        return blocks.compactMap { $0.intersection(with: day, now: now)?.duration }.reduce(0, +)
    }

    func availableHistoricalInterval(at proposedDate: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        let anchor = calendar.snappedToFiveMinutes(proposedDate)
        let day = calendar.dayInterval(containing: anchor)
        guard anchor >= day.start, anchor < day.end else { return nil }

        if let activeBlock, activeBlock.startedAt <= anchor { return nil }

        for block in blocks where block.startedAt < anchor.addingTimeInterval(1) && block.effectiveEnd(now: now) > anchor {
            return nil
        }
        let previousEnd = blocks
            .compactMap(\.endedAt)
            .filter { $0 <= anchor }
            .max() ?? day.start
        let nextStart = blocks.map(\.startedAt).filter { $0 >= anchor }.min() ?? day.end
        let gapEnd = min(day.end, nextStart)
        let end = min(anchor.addingTimeInterval(30 * 60), gapEnd)
        guard end.timeIntervalSince(anchor) >= 5 * 60, anchor >= max(day.start, previousEnd) else { return nil }
        return DateInterval(start: anchor, end: end)
    }

    func clampedInterval(
        for block: TimeBlock,
        proposedStart: Date,
        proposedEnd: Date,
        mode: TimelineEditMode,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval {
        guard let originalEnd = block.endedAt else {
            return DateInterval(start: block.startedAt, end: block.effectiveEnd(now: now))
        }
        let others = blocks.filter { $0.id != block.id }.sorted { $0.startedAt < $1.startedAt }
        let lowerBound = others.compactMap { candidate -> Date? in
            guard let end = candidate.endedAt, end <= block.startedAt else { return nil }
            return end
        }.max() ?? .distantPast
        let upperBound = others.filter { $0.startedAt >= originalEnd }.map(\.startedAt).min() ?? .distantFuture
        let minimum = 5.0 * 60.0

        switch mode {
        case .start:
            let snapped = calendar.snappedToFiveMinutes(proposedStart)
            let start = min(max(snapped, lowerBound), originalEnd.addingTimeInterval(-minimum))
            return DateInterval(start: start, end: originalEnd)
        case .end:
            let snapped = calendar.snappedToFiveMinutes(proposedEnd)
            let end = max(min(snapped, upperBound), block.startedAt.addingTimeInterval(minimum))
            return DateInterval(start: block.startedAt, end: end)
        case .move:
            return TimelineMoveResolver.nearestAvailableInterval(
                for: block,
                proposedStart: calendar.snappedToFiveMinutes(proposedStart),
                among: others
            )
        }
    }

    func reconcile() async {
        guard let database else { return }
        do {
            guard let block = try database.activeBlock() else {
                deadlineTask?.cancel()
                refresh()
                return
            }
            let current = Date()
            if let deadline = block.confirmationDeadline, deadline <= current {
                stop(blockID: block.id, at: deadline, reason: .reminderTimeout, notify: true)
                return
            }
            if let reminderAt = block.nextReminderAt, let deadline = block.confirmationDeadline {
                if reminderAt > current {
                    let result = await notifications.ensureReminder(for: block, at: reminderAt)
                    switch result {
                    case .scheduled:
                        removeWarning(.notifications)
                        removeWarning(.scheduling)
                    case .disabled:
                        setWarning(.notifications, "Notifications are disabled. Tracking will continue, but reminder timeouts are not active.")
                    case .failed(let message):
                        setWarning(.scheduling, "A reminder could not be rescheduled: \(message)")
                    }
                }
                armDeadline(for: block.id, at: deadline)
            } else if block.reminderIntervalSeconds != nil {
                switch await notifications.permissionState() {
                case .available:
                    await scheduleNextReminder(for: block.id, relativeTo: current)
                case .denied:
                    setWarning(.notifications, "Notifications are disabled. Tracking will continue, but reminder timeouts are not active.")
                case .undetermined:
                    break
                }
            }
            refresh()
        } catch { handle(error) }
    }

    func handleNotificationAction(identifier: String, blockID: UUID, kind: String) async {
        if kind == NotificationAction.automaticStopKind {
            reveal(blockID: blockID)
            return
        }
        guard kind == NotificationAction.reminderKind,
              let block = blocks.first(where: { $0.id == blockID }), block.isActive else {
            reveal(blockID: blockID)
            return
        }
        let handledAt = Date()
        if let deadline = block.confirmationDeadline, deadline <= handledAt {
            stop(blockID: block.id, at: deadline, reason: .reminderTimeout, notify: true)
            return
        }
        switch identifier {
        case NotificationAction.keepGoing:
            do {
                try database?.clearReminder(id: block.id)
                notifications.cancelReminder(for: block.id)
                refresh()
                await scheduleNextReminder(for: block.id, relativeTo: handledAt)
            } catch { handle(error) }
        case NotificationAction.stop:
            stop(blockID: block.id, at: handledAt, reason: .manual, notify: false)
        default:
            reveal(blockID: blockID)
        }
    }

    func handleSystemSleep(at date: Date = Date()) {
        guard let activeBlock else { return }
        stop(blockID: activeBlock.id, at: date, reason: .systemSleep, notify: true)
    }

    func prepareForTermination() {
        guard !hasPreparedForTermination else { return }
        hasPreparedForTermination = true
        guard let activeBlock else { return }
        stop(blockID: activeBlock.id, at: Date(), reason: .applicationQuit, notify: true)
    }

    func openTimeBlocks() {
        selectedDate = Date()
        presentTimeBlocksWindow()
    }

    func reveal(blockID: UUID) {
        refresh()
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        selectedDate = block.startedAt
        selectedBlockID = blockID
        presentTimeBlocksWindow()
    }

    /// Activates the app, switches the main window to Time Blocks, and brings it onto the
    /// current Space (menu-bar apps with `LSUIElement` otherwise leave the window stranded).
    private func presentTimeBlocksWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openTimeBlocksWindow, object: nil)
        Self.bringMainWindowToFront()
    }

    private static func bringMainWindowToFront() {
        let raise: () -> Void = {
            let candidates = NSApp.windows.filter { window in
                window.canBecomeKey
                    && window.contentView != nil
                    && !(window is NSPanel)
                    && window.frame.width >= 400
            }
            for window in candidates {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        raise()
        // openWindow / scene creation can land on a later run-loop turn.
        DispatchQueue.main.async(execute: raise)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: raise)
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func bootstrap() async {
        launchAtLogin.performFirstLaunchRegistrationIfNeeded()
        await reconcile()
    }

    private func scheduleNextReminder(for blockID: UUID, relativeTo basis: Date) async {
        guard let database,
              let block = try? database.block(id: blockID),
              block.isActive,
              let seconds = block.reminderIntervalSeconds else { return }
        let reminderAt = basis.addingTimeInterval(TimeInterval(seconds))
        let deadline = reminderAt.addingTimeInterval(5 * 60)
        switch await notifications.scheduleReminder(for: block, at: reminderAt) {
        case .scheduled:
            do {
                guard let latest = try database.block(id: blockID), latest.isActive else {
                    notifications.cancelReminder(for: blockID)
                    return
                }
                try database.setReminder(id: blockID, reminderAt: reminderAt, deadline: deadline)
                removeWarning(.notifications)
                removeWarning(.scheduling)
                refresh()
                armDeadline(for: blockID, at: deadline)
            } catch {
                notifications.cancelReminder(for: blockID)
                handle(error)
            }
        case .disabled:
            setWarning(.notifications, "Notifications are disabled. Tracking will continue, but reminder timeouts are not active.")
        case .failed(let message):
            setWarning(.scheduling, "A reminder could not be scheduled. Tracking will continue without a reminder timeout. \(message)")
        }
    }

    private func armDeadline(for blockID: UUID, at deadline: Date) {
        deadlineTask?.cancel()
        let delay = max(0, deadline.timeIntervalSinceNow)
        deadlineTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            guard self?.activeBlock?.id == blockID else { return }
            await self?.reconcile()
        }
    }

    private func stop(blockID: UUID, at date: Date, reason: StopReason, notify: Bool) {
        guard let database else { return }
        do {
            let completed = try database.completeBlock(id: blockID, at: date, reason: reason)
            notifications.cancelReminder(for: blockID)
            deadlineTask?.cancel()
            refresh()
            selectedBlockID = completed.id
            if notify { notifications.scheduleAutomaticStop(for: completed) }
        } catch { handle(error) }
    }

    private func refresh() {
        guard let database else { return }
        do {
            blocks = try database.allBlocks()
            if let selectedBlockID, !blocks.contains(where: { $0.id == selectedBlockID }) {
                self.selectedBlockID = nil
            }
            removeWarning(.database)
        } catch { handle(error) }
    }

    private func handle(_ error: Error) {
        NSLog("blktrckr error: %@", error.localizedDescription)
        setWarning(.database, error.localizedDescription)
    }

    private func setWarning(_ kind: AppWarning.Kind, _ message: String) {
        warnings.removeAll { $0.kind == kind }
        warnings.append(AppWarning(kind: kind, message: message))
    }

    private func removeWarning(_ kind: AppWarning.Kind) {
        warnings.removeAll { $0.kind == kind }
    }
}
