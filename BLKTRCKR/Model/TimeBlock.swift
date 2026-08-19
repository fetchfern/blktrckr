import AppKit
import Foundation
import SwiftUI

enum StopReason: String, Codable, CaseIterable, Sendable {
    case manual
    case replacedByNewBlock
    case applicationQuit
    case reminderTimeout
    case systemSleep
    case manualEntry

    func label(wasTimingEdited: Bool) -> String {
        switch (self, wasTimingEdited) {
        case (.manual, false): "Stopped manually"
        case (.manual, true): "Originally stopped manually"
        case (.replacedByNewBlock, false): "Stopped when another block started"
        case (.replacedByNewBlock, true): "Originally stopped when another block started"
        case (.applicationQuit, false): "Stopped due to application exit"
        case (.applicationQuit, true): "Originally stopped due to application exit"
        case (.reminderTimeout, false): "Stopped after reminder timeout"
        case (.reminderTimeout, true): "Originally stopped after reminder timeout"
        case (.systemSleep, false): "Stopped when the Mac went to sleep"
        case (.systemSleep, true): "Originally stopped when the Mac went to sleep"
        case (.manualEntry, _): "Manually entered"
        }
    }

    var notificationExplanation: String {
        switch self {
        case .reminderTimeout: "the reminder was not answered"
        case .systemSleep: "the Mac went to sleep"
        case .applicationQuit: "the application exited"
        case .manual: "it was stopped manually"
        case .replacedByNewBlock: "another block started"
        case .manualEntry: "it was entered manually"
        }
    }
}

struct TimeBlock: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var description: String? = nil
    var startedAt: Date
    var endedAt: Date?
    var reminderIntervalSeconds: Int?
    var nextReminderAt: Date?
    var confirmationDeadline: Date?
    var stopReason: StopReason?
    var wasTimingEdited: Bool

    var isActive: Bool { endedAt == nil }

    var stopLabel: String {
        guard let stopReason else { return "Currently running" }
        return stopReason.label(wasTimingEdited: wasTimingEdited)
    }

    func effectiveEnd(now: Date) -> Date { endedAt ?? now }

    func intersection(with day: DateInterval, now: Date) -> DateInterval? {
        let start = max(startedAt, day.start)
        let end = min(effectiveEnd(now: now), day.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

enum BlockDescription {
    static func normalized(_ description: String?) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ReminderChoice: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case oneHour
    case twoHours
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .fortyFiveMinutes: "45 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .never: "Never"
        }
    }

    var seconds: Int? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .fortyFiveMinutes: 45 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .never: nil
        }
    }
}

enum TimeText {
    static func menuElapsed(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func interval(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

enum BlockPalette {
    private static let colors: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.78),
        Color(red: 0.19, green: 0.58, blue: 0.53),
        Color(red: 0.56, green: 0.40, blue: 0.76),
        Color(red: 0.80, green: 0.43, blue: 0.26),
        Color(red: 0.33, green: 0.57, blue: 0.28),
        Color(red: 0.74, green: 0.34, blue: 0.51),
        Color(red: 0.20, green: 0.58, blue: 0.72),
        Color(red: 0.69, green: 0.49, blue: 0.19),
        Color(red: 0.42, green: 0.48, blue: 0.74),
        Color(red: 0.26, green: 0.61, blue: 0.39),
        Color(red: 0.72, green: 0.38, blue: 0.34),
        Color(red: 0.48, green: 0.43, blue: 0.70),
        Color(red: 0.18, green: 0.55, blue: 0.60),
        Color(red: 0.66, green: 0.46, blue: 0.28),
        Color(red: 0.38, green: 0.55, blue: 0.30),
        Color(red: 0.65, green: 0.35, blue: 0.59)
    ]

    static func color(for name: String) -> Color {
        let normalized = EventName.normalized(name)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

struct NameUsage: Equatable, Sendable {
    let normalizedName: String
    let displayName: String
    let count: Int
    let mostRecentUse: Date
}

enum NameCompletion {
    static func suggestion(for prefix: String, usages: [NameUsage]) -> String? {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return nil }
        let normalizedPrefix = trimmedPrefix.lowercased()

        return usages
            .filter {
                $0.normalizedName.hasPrefix(normalizedPrefix)
                    && $0.normalizedName != normalizedPrefix
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.mostRecentUse != $1.mostRecentUse { return $0.mostRecentUse > $1.mostRecentUse }
                return $0.normalizedName.localizedStandardCompare($1.normalizedName) == .orderedAscending
            }
            .first?
            .displayName
    }
}

extension Calendar {
    func dayInterval(containing date: Date) -> DateInterval {
        dateInterval(of: .day, for: date)!
    }

    func snappedToFiveMinutes(_ date: Date) -> Date {
        let day = startOfDay(for: date)
        let minutes = dateComponents([.minute], from: day, to: date).minute ?? 0
        let roundedMinutes = Int((Double(minutes) / 5.0).rounded()) * 5
        return self.date(byAdding: .minute, value: roundedMinutes, to: day) ?? date
    }
}
