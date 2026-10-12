import AppKit
import XCTest
import WhiskerFlowCore
import WhiskerFlowAppSupport
@testable import WhiskerFlow

@MainActor
private final class RecordingPasteService: TextDeliveryService {
    var hasAccessibilityPermission = true
    private(set) var pasted: [String] = []
    func requestAccessibilityPermission() {}
    func copy(_ text: String) {}
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        pasted.append(text)
        return PasteDeliveryReceipt(state: .verified, text: text, message: "Pasted", retrySelection: nil)
    }
}

@MainActor
private final class MemoryOnboardingStore: OnboardingProgressStoring {
    var stored: OnboardingProgress?
    init(_ stored: OnboardingProgress? = nil) { self.stored = stored }
    func load() -> OnboardingProgress? { stored }
    func save(_ progress: OnboardingProgress) { stored = progress }
    func clear() { stored = nil }
}

final class OnboardingIntegrationTests: XCTestCase {
    // MARK: Practice delivery

    /// A test host is not an app, so another running app stands in for "this app".
    @MainActor
    private func standIn() throws -> NSRunningApplication {
        try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier > 0 })
    }

    @MainActor
    func testPracticeDictationIntoThisAppLandsInThePracticeField() async throws {
        let base = RecordingPasteService()
        let router = InAppPracticeDelivery(base: base)
        let app = try standIn()
        router.ownProcessIdentifier = app.processIdentifier
        var field: [String] = []
        router.practiceField = { field.append($0) }
        var posted = false
        let receipt = await router.paste("Let's meet at 3.", into: app, replacing: nil, onPosted: { posted = true })
        XCTAssertEqual(field, ["Let's meet at 3."])
        XCTAssertTrue(base.pasted.isEmpty, "PasteService refuses this app as a destination; the router must not reach it")
        XCTAssertEqual(receipt.state, .verified)
        XCTAssertTrue(posted)
    }

    @MainActor
    func testOtherDeliveriesPassStraightThrough() async throws {
        let base = RecordingPasteService()
        let router = InAppPracticeDelivery(base: base)
        let app = try standIn()
        router.ownProcessIdentifier = app.processIdentifier
        _ = await router.paste("No practice screen", into: app, replacing: nil)
        XCTAssertEqual(base.pasted, ["No practice screen"])

        var field: [String] = []
        router.practiceField = { field.append($0) }
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && $0.processIdentifier != app.processIdentifier
        })
        _ = await router.paste("Another app", into: other, replacing: nil)
        XCTAssertEqual(base.pasted, ["No practice screen", "Another app"])
        XCTAssertTrue(field.isEmpty)
    }

    // MARK: Controller

    @MainActor
    func testFreshInstallPresentsAndPersistsEveryTransition() {
        let store = MemoryOnboardingStore()
        var events: [OnboardingTelemetryEvent] = []
        let controller = OnboardingController(store: store, record: { events.append($0) })
        XCTAssertTrue(controller.presentIfNeeded(hasHistory: false, hadPreviousLaunch: false, permissionsReady: false))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(store.stored?.current, .welcome)

        controller.advance(OnboardingConditions())
        XCTAssertEqual(store.stored?.current, .permissions, "saved on every step so a quit resumes here")
        XCTAssertEqual(events.map(\.outcome), [.viewed, .completed, .viewed])

        // A relaunch reads the same store and resumes.
        let relaunched = OnboardingController(store: store, record: { events.append($0) })
        XCTAssertTrue(relaunched.presentIfNeeded(hasHistory: false, hadPreviousLaunch: true, permissionsReady: false))
        XCTAssertEqual(relaunched.current, .permissions)
        XCTAssertEqual(events.last, OnboardingTelemetryEvent(step: .permissions, outcome: .resumed))
    }

    @MainActor
    func testExistingUserIsMarkedDoneWithoutFunnelTelemetry() {
        let store = MemoryOnboardingStore()
        var events: [OnboardingTelemetryEvent] = []
        let controller = OnboardingController(store: store, record: { events.append($0) })
        XCTAssertFalse(controller.presentIfNeeded(hasHistory: true, hadPreviousLaunch: true, permissionsReady: true))
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(store.stored?.isFinished == true)
        XCTAssertTrue(events.isEmpty, "a user who never saw setup must not count as finishing it")
    }

    @MainActor
    func testFinishingClosesSetupAndRunSetupAgainStartsOver() {
        let store = MemoryOnboardingStore(OnboardingProgress(current: .done, furthest: .done, startedAt: Date()))
        let controller = OnboardingController(store: store, record: { _ in })
        controller.present()
        controller.advance(OnboardingConditions(microphoneGranted: true, accessibilityGranted: true))
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(store.stored?.isFinished == true)

        controller.restart()
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.current, .welcome)
        XCTAssertFalse(store.stored?.isFinished == true)
    }

    @MainActor
    func testSetUpLaterKeepsProgressAndIsNotForcedBackOnce() {
        let store = MemoryOnboardingStore()
        let controller = OnboardingController(store: store, record: { _ in })
        controller.present()
        controller.advance(OnboardingConditions())
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(store.stored?.current, .permissions)
        XCTAssertFalse(OnboardingController(store: store, record: { _ in })
            .presentIfNeeded(hasHistory: false, hadPreviousLaunch: true, permissionsReady: true))
    }

    @MainActor
    func testAppSettingsKnowsWhetherThisInstallLaunchedBefore() {
        let name = "WhiskerFlow.onboarding-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertFalse(first.hadPreviousLaunch)
        let second = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertTrue(second.hadPreviousLaunch)
    }
}
