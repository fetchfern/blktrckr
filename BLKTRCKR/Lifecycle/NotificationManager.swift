@preconcurrency import UserNotifications
import Foundation

enum ReminderSchedulingResult {
    case scheduled
    case disabled
    case failed(String)
}

enum NotificationPermissionState {
    case available
    case denied
    case undetermined
}

enum NotificationAction {
    static let reminderCategory = "TIME_BLOCK_REMINDER"
    static let keepGoing = "KEEP_GOING"
    static let stop = "STOP_BLOCK"
    static let reminderKind = "reminder"
    static let automaticStopKind = "automaticStop"
}

enum NotificationCopy {
    static func reminderBody(for block: TimeBlock, at scheduledDate: Date) -> String {
        let elapsed = TimeText.duration(scheduledDate.timeIntervalSince(block.startedAt))
        return "\(block.name) has been running for \(elapsed)."
    }
}

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    private init() {
        let keepGoing = UNNotificationAction(
            identifier: NotificationAction.keepGoing,
            title: "Keep Going"
        )
        let stop = UNNotificationAction(
            identifier: NotificationAction.stop,
            title: "Stop",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: NotificationAction.reminderCategory,
            actions: [keepGoing, stop],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func scheduleReminder(for block: TimeBlock, at date: Date) async -> ReminderSchedulingResult {
        switch await authorizationState(requestIfNeeded: true) {
        case .disabled:
            return .disabled
        case .failed(let message):
            return .failed(message)
        case .available:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "Still working?"
        content.body = NotificationCopy.reminderBody(for: block, at: date)
        content.categoryIdentifier = NotificationAction.reminderCategory
        content.sound = .default
        content.userInfo = [
            "kind": NotificationAction.reminderKind,
            "blockID": block.id.uuidString
        ]

        let delay = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminderIdentifier(for: block.id),
            content: content,
            trigger: trigger
        )
        do {
            center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(for: block.id)])
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func ensureReminder(for block: TimeBlock, at date: Date) async -> ReminderSchedulingResult {
        let identifier = reminderIdentifier(for: block.id)
        let requests = await center.pendingNotificationRequests()
        if requests.contains(where: { $0.identifier == identifier }) { return .scheduled }
        return await scheduleReminder(for: block, at: date)
    }

    func cancelReminder(for blockID: UUID) {
        let identifier = reminderIdentifier(for: blockID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func scheduleAutomaticStop(for block: TimeBlock) {
        guard let endedAt = block.endedAt, let reason = block.stopReason else { return }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium

        let content = UNMutableNotificationContent()
        content.title = "\(block.name) stopped"
        content.body = "Stopped at \(formatter.string(from: endedAt)) because \(reason.notificationExplanation)."
        content.sound = .default
        content.userInfo = [
            "kind": NotificationAction.automaticStopKind,
            "blockID": block.id.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: "automatic-stop.\(block.id.uuidString).\(endedAt.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { NSLog("Could not schedule automatic-stop notification: %@", error.localizedDescription) }
        }
    }

    func permissionState() async -> NotificationPermissionState {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .available
        case .notDetermined:
            return .undetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private enum AuthorizationState {
        case available
        case disabled
        case failed(String)
    }

    private func authorizationState(requestIfNeeded: Bool) async -> AuthorizationState {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .available
        case .denied:
            return .disabled
        case .notDetermined where requestIfNeeded:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound]) ? .available : .disabled
            } catch {
                return .failed(error.localizedDescription)
            }
        case .notDetermined:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    private func reminderIdentifier(for id: UUID) -> String {
        "reminder.\(id.uuidString)"
    }
}
