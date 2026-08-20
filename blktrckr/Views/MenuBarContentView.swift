import Sparkle
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    @Environment(\.openWindow) private var openWindow
    let updater: SPUUpdater

    private var startedTime: String {
        guard let active = state.activeBlock else { return "" }
        return active.startedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        if let active = state.activeBlock {
            if let icon = eventAppearances.icon(for: active.name) {
                Label(active.name, systemImage: icon)
            } else {
                Text(active.name)
            }
            if let description = active.description {
                Text(description)
            }
            Text("Started \(startedTime)")
            Divider()
            Button("Stop Time Block") { state.stopActiveManually() }
            Button("Start Time Block…") { showStart() }
        } else {
            Button("Start Time Block…") { showStart() }
        }

        Divider()
        Button("Open Time Blocks") {
            openWindow(id: "main")
            state.openTimeBlocks()
        }
        SettingsLink { Text("Settings") }
        CheckForUpdatesView(updater: updater)
        Button("Quit") {
            state.prepareForTermination()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showStart() {
        openWindow(id: "main")
        state.presentStart()
    }
}
