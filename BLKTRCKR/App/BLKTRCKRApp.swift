import SwiftUI

@main
struct BLKTRCKRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Time Blocks", id: "main") {
            MainWindowView()
                .environmentObject(state)
                .environmentObject(state.eventAppearances)
                .frame(minWidth: 850, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 640)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Delete Time Block") { state.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(state.selectedBlock?.isActive != false)
            }
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(state)
                .environmentObject(state.eventAppearances)
        } label: {
            MenuBarStatusLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.eventAppearances)
                .frame(width: 720, height: 580)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let active = state.activeBlock {
                Label(TimeText.menuElapsed(from: active.startedAt, to: state.now), systemImage: "clock")
            } else {
                Image(systemName: "clock")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTimeBlocksWindow)) { _ in
            openWindow(id: "main")
        }
    }
}
