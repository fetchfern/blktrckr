import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater

        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates, options: [.initial, .new])
            .assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates, options: [.initial, .new])
            .assign(to: &$allowsAutomaticUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
    }
}

@MainActor
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: UpdaterViewModel

    init(updater: SPUUpdater) {
        _viewModel = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { viewModel.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
struct UpdaterSettingsView: View {
    @StateObject private var viewModel: UpdaterViewModel

    init(updater: SPUUpdater) {
        _viewModel = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Toggle(
            "Automatically check for updates",
            isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { viewModel.setAutomaticallyChecksForUpdates($0) }
            )
        )

        Toggle(
            "Automatically download and install updates",
            isOn: Binding(
                get: { viewModel.automaticallyDownloadsUpdates },
                set: { viewModel.setAutomaticallyDownloadsUpdates($0) }
            )
        )
        .disabled(!viewModel.allowsAutomaticUpdates)

        HStack {
            Button("Check Now") { viewModel.checkForUpdates() }
                .disabled(!viewModel.canCheckForUpdates)

            Spacer()

            Text(versionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return version == build ? "Version \(version)" : "Version \(version) (\(build))"
    }
}
