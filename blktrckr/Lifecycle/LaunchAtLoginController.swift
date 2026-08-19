import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var warning: String?

    private let service = SMAppService.mainApp
    private let attemptedKey = "didAttemptInitialLaunchAtLoginRegistration"

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            warning = nil
        case .requiresApproval:
            isEnabled = false
            warning = "Launch at Login needs approval in System Settings."
        case .notRegistered:
            isEnabled = false
            warning = nil
        case .notFound:
            isEnabled = false
            warning = "Launch at Login is unavailable for this copy of the app."
        @unknown default:
            isEnabled = false
            warning = "Launch at Login status is unavailable."
        }
    }

    func performFirstLaunchRegistrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: attemptedKey) else { refresh(); return }
        UserDefaults.standard.set(true, forKey: attemptedKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refresh()
        } catch {
            warning = "Launch at Login could not be updated: \(error.localizedDescription)"
            refreshPreservingWarning()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshPreservingWarning() {
        let existingWarning = warning
        refresh()
        if warning == nil { warning = existingWarning }
    }
}
