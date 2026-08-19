import AppKit
import SwiftUI

enum EventName {
    static func display(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ name: String) -> String {
        display(name).lowercased()
    }
}

struct EventColor: Codable, Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ color: Color) {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var labelColor: Color {
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance > 0.62 ? Color.black.opacity(0.82) : .white
    }
}

struct EventColorPreset: Identifiable {
    let id: String
    let name: String
    let value: EventColor

    init(_ name: String, red: Double, green: Double, blue: Double) {
        id = name
        self.name = name
        value = EventColor(red: red, green: green, blue: blue)
    }

    static let choices = [
        EventColorPreset("Ocean", red: 0.20, green: 0.47, blue: 0.78),
        EventColorPreset("Teal", red: 0.19, green: 0.58, blue: 0.53),
        EventColorPreset("Forest", red: 0.33, green: 0.57, blue: 0.28),
        EventColorPreset("Amber", red: 0.75, green: 0.51, blue: 0.18),
        EventColorPreset("Coral", red: 0.78, green: 0.39, blue: 0.31),
        EventColorPreset("Rose", red: 0.74, green: 0.34, blue: 0.51),
        EventColorPreset("Violet", red: 0.56, green: 0.40, blue: 0.76),
        EventColorPreset("Indigo", red: 0.36, green: 0.43, blue: 0.72)
    ]
}

struct EventIconChoice: Identifiable {
    let symbol: String?
    let name: String

    var id: String { symbol ?? "none" }

    static let choices = [
        EventIconChoice(symbol: nil, name: "No Icon"),
        EventIconChoice(symbol: "laptopcomputer", name: "Computer"),
        EventIconChoice(symbol: "terminal.fill", name: "Terminal"),
        EventIconChoice(symbol: "curlybraces", name: "Code"),
        EventIconChoice(symbol: "hammer.fill", name: "Build"),
        EventIconChoice(symbol: "person.2.fill", name: "Meeting"),
        EventIconChoice(symbol: "message.fill", name: "Messages"),
        EventIconChoice(symbol: "doc.text.fill", name: "Document"),
        EventIconChoice(symbol: "checkmark.circle.fill", name: "Tasks"),
        EventIconChoice(symbol: "lightbulb.fill", name: "Idea"),
        EventIconChoice(symbol: "paintbrush.fill", name: "Design"),
        EventIconChoice(symbol: "book.fill", name: "Reading"),
        EventIconChoice(symbol: "cup.and.saucer.fill", name: "Break")
    ]
}

private struct EventAppearance: Codable, Equatable {
    var displayName: String
    var color: EventColor?
    var icon: String?
}

@MainActor
final class EventAppearanceStore: ObservableObject {
    @Published private var mappings: [String: EventAppearance]

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "eventAppearanceMappingsV1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: EventAppearance].self, from: data) {
            mappings = saved
        } else {
            mappings = [:]
        }
    }

    func eventNames(from blocks: [TimeBlock]) -> [String] {
        var names = mappings.mapValues(\.displayName)
        for block in blocks {
            let displayName = EventName.display(block.name)
            names[EventName.normalized(displayName)] = displayName
        }
        return names.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func register(name: String) {
        let displayName = EventName.display(name)
        guard !displayName.isEmpty else { return }
        let key = EventName.normalized(displayName)
        if mappings[key] == nil {
            mappings[key] = EventAppearance(displayName: displayName, color: nil, icon: nil)
            save()
        }
    }

    func color(for name: String) -> Color {
        colorOverride(for: name)?.color ?? BlockPalette.color(for: name)
    }

    func labelColor(for name: String) -> Color {
        colorOverride(for: name)?.labelColor ?? .white
    }

    func colorOverride(for name: String) -> EventColor? {
        mappings[EventName.normalized(name)]?.color
    }

    func icon(for name: String) -> String? {
        mappings[EventName.normalized(name)]?.icon
    }

    func hasOverrides(for name: String) -> Bool {
        guard let appearance = mappings[EventName.normalized(name)] else { return false }
        return appearance.color != nil || appearance.icon != nil
    }

    func hasAppearanceEntry(for name: String) -> Bool {
        mappings[EventName.normalized(name)] != nil
    }

    func setColor(_ color: EventColor?, for name: String) {
        update(name: name) { $0.color = color }
    }

    func setIcon(_ icon: String?, for name: String) {
        update(name: name) { $0.icon = icon }
    }

    func deleteOverride(for name: String) {
        mappings.removeValue(forKey: EventName.normalized(name))
        save()
    }

    private func update(name: String, change: (inout EventAppearance) -> Void) {
        let displayName = EventName.display(name)
        guard !displayName.isEmpty else { return }
        let key = EventName.normalized(displayName)
        var appearance = mappings[key]
            ?? EventAppearance(displayName: displayName, color: nil, icon: nil)
        appearance.displayName = displayName
        change(&appearance)
        mappings[key] = appearance
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
