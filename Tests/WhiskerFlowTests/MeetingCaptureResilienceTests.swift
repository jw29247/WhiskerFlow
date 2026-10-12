import Foundation
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

final class MeetingCaptureResilienceTests: XCTestCase {
    func testDeterministicDeliveryFailuresAreHeldAndOutagesAreNotCounted() {
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(TranscriptionError.emptyTranscript), .permanent)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(MeetingChunkStoreError.checksumMismatch), .permanent)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(MeetingChunkStoreError.keychain(-25308)), .transient)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(URLError(.notConnectedToInternet)), .transient)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(MeetingAtlasClientError.server("busy")), .transient)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(MeetingLibraryError.saveFailed), .transient)
        XCTAssertEqual(MeetingDeliveryFailurePolicy.classify(NSError(domain: "decoder", code: 1)), .counted)
    }

    func testMixKeepsAdvancingWhenOneSourceStops() {
        let lag = MeetingAudioCaptureService.maximumPendingMixLagSamples
        // Normal jitter never pads mid-meeting.
        XCTAssertNil(MeetingAudioCaptureService.mixPadding(microphonePending: 4_000, systemPending: 0, flushRemainder: false))
        // A dead microphone: the system source runs ahead and is mixed
        // against silence instead of growing without bound.
        let dead = MeetingAudioCaptureService.mixPadding(microphonePending: 0, systemPending: lag + 1, flushRemainder: false)
        XCTAssertEqual(dead?.track, .microphone)
        XCTAssertEqual(dead?.count, lag + 1)
        let deadSystem = MeetingAudioCaptureService.mixPadding(microphonePending: lag + 5, systemPending: 2, flushRemainder: false)
        XCTAssertEqual(deadSystem?.track, .system)
        XCTAssertEqual(deadSystem?.count, lag + 3)
        // The final flush covers the longer source.
        let flush = MeetingAudioCaptureService.mixPadding(microphonePending: 100, systemPending: 40, flushRemainder: true)
        XCTAssertEqual(flush?.track, .system)
        XCTAssertEqual(flush?.count, 60)
        XCTAssertNil(MeetingAudioCaptureService.mixPadding(microphonePending: 7, systemPending: 7, flushRemainder: true))
    }

    func testSourceGapIsReportedWhenTracksEndAtDifferentLengths() {
        let second = MeetingPCMChunkWriter.sampleRate
        XCTAssertFalse(MeetingAudioCaptureService.sourceCountsDiverge(microphone: 10 * second, system: 10 * second - 4_000))
        XCTAssertTrue(MeetingAudioCaptureService.sourceCountsDiverge(microphone: 0, system: 60 * second))
        // Two hours of 100 ppm device-clock drift is not a gap.
        let twoHours = 2 * 3_600 * second
        XCTAssertFalse(MeetingAudioCaptureService.sourceCountsDiverge(microphone: twoHours, system: twoHours - twoHours / 10_000))
    }

    @MainActor
    func testUnavailableSelectedMicrophoneFallsBackToBuiltInThenDefault() {
        XCTAssertEqual(
            MeetingAudioCaptureService.microphoneCandidates(for: .device(uid: "headset"), builtInUID: "builtin"),
            [.device(uid: "headset"), .device(uid: "builtin"), .systemDefault]
        )
        // A Mac mini has no built-in microphone: the default input is still tried.
        XCTAssertEqual(
            MeetingAudioCaptureService.microphoneCandidates(for: .device(uid: "usb"), builtInUID: nil),
            [.device(uid: "usb"), .systemDefault]
        )
        XCTAssertEqual(
            MeetingAudioCaptureService.microphoneCandidates(for: .systemDefault, builtInUID: "builtin"),
            [.systemDefault, .device(uid: "builtin")]
        )
        XCTAssertGreaterThanOrEqual(MeetingAudioCaptureService.preferredMicrophoneFlowTimeoutSeconds, 5)
    }
}
