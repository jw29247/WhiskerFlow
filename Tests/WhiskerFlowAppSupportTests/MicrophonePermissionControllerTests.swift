import XCTest
@testable import WhiskerFlowAppSupport

@MainActor
final class MicrophonePermissionControllerTests: XCTestCase {
    func testAuthorizedProviderIsGrantedAtInitialization() {
        let provider = StubMicrophoneAuthorizationProvider(state: .authorized)

        let controller = MicrophonePermissionController(provider: provider)

        XCTAssertEqual(controller.authorizationState, .authorized)
        XCTAssertTrue(controller.isGranted)
        XCTAssertNil(controller.recoveryAction)
    }

    func testDeniedStateOffersSettingsRecoveryWithoutRequestingAgain() async {
        let provider = StubMicrophoneAuthorizationProvider(state: .denied)
        let controller = MicrophonePermissionController(provider: provider)

        let resolvedState = await controller.requestIfNeeded()

        XCTAssertEqual(resolvedState, .denied)
        XCTAssertEqual(controller.recoveryAction, .openSettings)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testRestrictedStateOffersSettingsRecoveryWithoutRequestingAgain() async {
        let provider = StubMicrophoneAuthorizationProvider(state: .restricted)
        let controller = MicrophonePermissionController(provider: provider)

        let resolvedState = await controller.requestIfNeeded()

        XCTAssertEqual(resolvedState, .restricted)
        XCTAssertEqual(controller.recoveryAction, .openSettings)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testApplicationActivationRechecksProviderState() {
        let provider = StubMicrophoneAuthorizationProvider(state: .denied)
        let controller = MicrophonePermissionController(provider: provider)
        provider.state = .authorized

        controller.refreshForApplicationActivation()

        XCTAssertEqual(controller.authorizationState, .authorized)
        XCTAssertTrue(controller.isGranted)
    }

    func testRequestTransitionsFromNotDeterminedToProviderResult() async {
        let provider = StubMicrophoneAuthorizationProvider(
            state: .notDetermined,
            stateAfterRequest: .authorized
        )
        let controller = MicrophonePermissionController(provider: provider)

        let resolvedState = await controller.requestIfNeeded()

        XCTAssertEqual(resolvedState, .authorized)
        XCTAssertEqual(controller.authorizationState, .authorized)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testRecoveryActionMatchesEachAuthorizationState() {
        let provider = StubMicrophoneAuthorizationProvider(state: .notDetermined)
        let controller = MicrophonePermissionController(provider: provider)

        XCTAssertEqual(controller.recoveryAction, .request)

        provider.state = .denied
        controller.refresh()
        XCTAssertEqual(controller.recoveryAction, .openSettings)

        provider.state = .restricted
        controller.refresh()
        XCTAssertEqual(controller.recoveryAction, .openSettings)

        provider.state = .authorized
        controller.refresh()
        XCTAssertNil(controller.recoveryAction)
    }

    func testPresentationDistinguishesEachAuthorizationState() {
        let provider = StubMicrophoneAuthorizationProvider(state: .notDetermined)
        let controller = MicrophonePermissionController(provider: provider)

        XCTAssertEqual(controller.detail, "Needed to record your voice.")
        XCTAssertEqual(controller.captureFailureMessage, "Microphone permission was not granted")

        provider.state = .denied
        controller.refresh()
        XCTAssertEqual(
            controller.detail,
            "Microphone access is off. Enable WhiskerFlow in System Settings."
        )
        XCTAssertEqual(
            controller.captureFailureMessage,
            "Microphone access is off — open Microphone Settings"
        )

        provider.state = .restricted
        controller.refresh()
        XCTAssertEqual(controller.detail, "Microphone access is restricted by macOS.")
        XCTAssertEqual(
            controller.captureFailureMessage,
            "Microphone access is restricted by macOS"
        )

        provider.state = .authorized
        controller.refresh()
        XCTAssertEqual(controller.detail, "Ready to record.")
        XCTAssertNil(controller.captureFailureMessage)
    }

    func testCaptureErrorPresentationPreservesActionableLocalizedDescription() {
        let error = StubCaptureError.deviceUnavailable

        XCTAssertEqual(
            CaptureErrorPresentation.message(for: error),
            "The selected microphone is no longer available."
        )
    }
}

private enum StubCaptureError: LocalizedError {
    case deviceUnavailable

    var errorDescription: String? {
        "The selected microphone is no longer available."
    }
}

@MainActor
private final class StubMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding {
    var state: MicrophoneAuthorizationState
    var stateAfterRequest: MicrophoneAuthorizationState
    private(set) var requestCount = 0

    init(
        state: MicrophoneAuthorizationState,
        stateAfterRequest: MicrophoneAuthorizationState? = nil
    ) {
        self.state = state
        self.stateAfterRequest = stateAfterRequest ?? state
    }

    var authorizationState: MicrophoneAuthorizationState {
        state
    }

    func requestAccess() async {
        requestCount += 1
        state = stateAfterRequest
    }
}
