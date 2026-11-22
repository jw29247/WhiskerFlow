import Foundation
import ServiceManagement
import WhiskerFlowAppSupport
import XCTest
@testable import WhiskerFlow

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var registerError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    var openSettingsCalls = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }

    func openSystemSettings() { openSettingsCalls += 1 }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testSwitchFollowsTheReportedStatus() {
        let cases: [(SMAppService.Status, isOn: Bool, requiresApproval: Bool)] = [
            (.enabled, true, false),
            (.notRegistered, false, false),
            (.requiresApproval, true, true),
            (.notFound, false, false),
        ]
        for (status, isOn, requiresApproval) in cases {
            let service = FakeLoginItemService(status: status)
            let controller = LaunchAtLoginController(service: service)
            controller.refresh()
            XCTAssertEqual(controller.isOn, isOn, "status \(status.rawValue)")
            XCTAssertEqual(controller.requiresApproval, requiresApproval, "status \(status.rawValue)")
            XCTAssertNil(controller.failure)
        }
    }

    /// Removing WhiskerFlow in System Settings turns the switch off on the
    /// next refresh, whatever was requested here.
    func testRefreshPicksUpAChangeMadeInSystemSettings() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)
        controller.set(true)
        XCTAssertTrue(controller.isOn)
        service.status = .notRegistered
        controller.refresh()
        XCTAssertFalse(controller.isOn)
    }

    func testTogglingRegistersAndUnregistersOnce() {
        let service = FakeLoginItemService(status: .notRegistered)
        var intents: [Bool] = []
        let controller = LaunchAtLoginController(service: service) { intents.append($0) }

        controller.set(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertTrue(controller.isOn)

        controller.set(false)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(intents, [true, false])
    }

    func testTurningOffAnItemAwaitingApprovalUnregistersIt() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)
        controller.refresh()
        controller.set(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testFailedRegisterLeavesTheSwitchOffAndShowsTheReason() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(domain: "Test", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Operation not permitted."])
        let controller = LaunchAtLoginController(service: service)

        controller.set(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.failure, "Couldn’t turn on launch at login: Operation not permitted.")

        service.registerError = nil
        controller.set(true)
        XCTAssertTrue(controller.isOn)
        XCTAssertNil(controller.failure, "a later success clears the reason")
    }

    func testOpenLoginItemsGoesThroughTheService() {
        let service = FakeLoginItemService(status: .requiresApproval)
        LaunchAtLoginController(service: service).openLoginItemsSettings()
        XCTAssertEqual(service.openSettingsCalls, 1)
    }

    /// Settings wires the injected service; the stored default no longer
    /// drives the switch.
    func testSettingsReadTheSystemNotTheStoredDefault() throws {
        let name = "WhiskerFlow.launch-at-login-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "launchAtLogin")
        let service = FakeLoginItemService(status: .notRegistered)
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name),
                                   loginItemService: service)
        settings.launchAtLogin.refresh()
        XCTAssertFalse(settings.launchAtLogin.isOn)

        settings.launchAtLogin.set(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(defaults.object(forKey: "launchAtLogin") as? Bool, true, "the request is still remembered")
    }
}
