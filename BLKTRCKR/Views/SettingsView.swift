import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    @State private var newEventName = ""

    private var controller: LaunchAtLoginController { state.launchAtLogin }
    private var eventNames: [String] { eventAppearances.eventNames(from: state.blocks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                generalSection
                eventAppearanceSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .onAppear { controller.refresh() }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General")
                .font(.title3.weight(.semibold))

            Toggle(
                "Open at Login",
                isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )
            )

            if let warning = controller.warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(warning)
                            .font(.callout)
                        Button("Open Login Item Settings") { controller.openSystemSettings() }
                    }
                }
            }
        }
        .settingsSectionBackground()
    }

    private var eventAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Event Appearance")
                    .font(.title3.weight(.semibold))
                Text("Choose a color and built-in icon for each time block name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Event name", text: $newEventName)
                    .onSubmit(addEventName)
                Button("Add", action: addEventName)
                    .disabled(EventName.display(newEventName).isEmpty)
            }

            if eventNames.isEmpty {
                Text("Tracked event names will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    ForEach(eventNames, id: \.self) { eventName in
                        EventAppearanceRow(eventName: eventName)
                            .environmentObject(eventAppearances)

                        if eventName != eventNames.last {
                            Divider()
                        }
                    }
                }
            }
        }
        .settingsSectionBackground()
    }

    private func addEventName() {
        let displayName = EventName.display(newEventName)
        guard !displayName.isEmpty else { return }
        eventAppearances.register(name: displayName)
        newEventName = ""
    }
}

private struct EventAppearanceRow: View {
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    let eventName: String

    private var selectedColor: EventColor? {
        eventAppearances.colorOverride(for: eventName)
    }

    private var selectedIcon: EventIconChoice {
        let symbol = eventAppearances.icon(for: eventName)
        return EventIconChoice.choices.first(where: { $0.symbol == symbol })
            ?? EventIconChoice.choices[0]
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { eventAppearances.color(for: eventName) },
            set: { color in
                guard let value = EventColor(color) else { return }
                eventAppearances.setColor(value, for: eventName)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(eventAppearances.color(for: eventName))
                    .frame(width: 38, height: 32)
                    .overlay {
                        if let icon = eventAppearances.icon(for: eventName) {
                            Image(systemName: icon)
                                .foregroundStyle(eventAppearances.labelColor(for: eventName))
                        }
                    }

                Text(eventName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                iconMenu

                Button(role: .destructive) {
                    eventAppearances.deleteOverride(for: eventName)
                } label: {
                    Label("Delete Override", systemImage: "trash")
                }
                .disabled(!eventAppearances.hasAppearanceEntry(for: eventName))
            }

            HStack(spacing: 9) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)

                colorButton(
                    color: eventAppearances.color(for: eventName),
                    selected: selectedColor == nil,
                    label: "Automatic color"
                ) {
                    eventAppearances.setColor(nil, for: eventName)
                }

                ForEach(EventColorPreset.choices) { preset in
                    colorButton(
                        color: preset.value.color,
                        selected: selectedColor == preset.value,
                        label: preset.name
                    ) {
                        eventAppearances.setColor(preset.value, for: eventName)
                    }
                }

                Divider()
                    .frame(height: 20)

                ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Choose a custom color")
            }
        }
        .padding(.vertical, 14)
    }

    private var iconMenu: some View {
        Menu {
            ForEach(EventIconChoice.choices) { choice in
                Button {
                    eventAppearances.setIcon(choice.symbol, for: eventName)
                } label: {
                    if let symbol = choice.symbol {
                        Label(choice.name, systemImage: symbol)
                    } else {
                        Label(choice.name, systemImage: "circle.slash")
                    }
                }
            }
        } label: {
            Label(selectedIcon.name, systemImage: selectedIcon.symbol ?? "circle.slash")
                .frame(minWidth: 105, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func colorButton(
        color: Color,
        selected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(selected ? Color.primary : Color.clear, lineWidth: 2)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private extension View {
    func settingsSectionBackground() -> some View {
        padding(18)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}
