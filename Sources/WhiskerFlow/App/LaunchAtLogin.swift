import Foundation
import Observation
import ServiceManagement

/// The system's login item for this app. Behind a protocol so the UI preview
/// and tests never register or unregister a real login item.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// "Launch at login" as the system reports it. The user can remove the item in
/// System Settings › General › Login Items, or macOS can hold it for approval,
/// so the switch reads the system rather than what was last requested.
@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: SMAppService.Status = .notRegistered
    /// Why the last change didn't take, in words for the user.
    private(set) var failure: String?
    @ObservationIgnored private let service: LoginItemService
    @ObservationIgnored private let rememberIntent: (Bool) -> Void

    init(service: LoginItemService, rememberIntent: @escaping (Bool) -> Void = { _ in }) {
        self.service = service
        self.rememberIntent = rememberIntent
    }

    /// Registered counts as on even while waiting for approval, so the user can
    /// still turn it off here; `requiresApproval` explains why it isn't active.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func set(_ enabled: Bool) {
        rememberIntent(enabled)
        failure = nil
        let current = service.status
        do {
            if enabled {
                if current != .enabled, current != .requiresApproval { try service.register() }
            } else if current == .enabled || current == .requiresApproval {
                try service.unregister()
            }
        } catch {
            failure = enabled
                ? "Couldn’t turn on launch at login: \(error.localizedDescription)"
                : "Couldn’t turn off launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        service.openSystemSettings()
    }
}
