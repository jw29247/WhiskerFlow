import XCTest
@testable import WhiskerFlowAppSupport
import WhiskerFlowCore

final class OnboardingMicrophoneCheckTests: XCTestCase {
    private func feed(_ check: inout OnboardingMicrophoneCheck, level: Float, peak: Float = 0.3,
                      from start: TimeInterval, seconds: TimeInterval) -> TimeInterval {
        var time = start
        while time < start + seconds {
            check.ingest(level: level, peak: peak, at: time)
            time += 0.1
        }
        return time
    }

    func testSpeechIsDetectedAfterEnoughVoicedAudio() {
        var check = OnboardingMicrophoneCheck()
        var time = feed(&check, level: 0.08, from: 0, seconds: 1)
        XCTAssertEqual(check.state, .listening)
        time = feed(&check, level: 0.6, from: time, seconds: 0.6)
        XCTAssertEqual(check.state, .heardSpeech)
        _ = feed(&check, level: 0.02, from: time, seconds: 6)
        XCTAssertEqual(check.state, .heardSpeech, "a heard voice stays heard")
    }

    func testBriefBurstsAccumulateAcrossPauses() {
        var check = OnboardingMicrophoneCheck()
        var time: TimeInterval = 0
        for _ in 0..<3 {
            time = feed(&check, level: 0.55, from: time, seconds: 0.15)
            time = feed(&check, level: 0.05, from: time, seconds: 0.3)
        }
        XCTAssertEqual(check.state, .heardSpeech)
    }

    func testRoomToneAloneEndsTooQuiet() {
        var check = OnboardingMicrophoneCheck()
        _ = feed(&check, level: 0.07, from: 0, seconds: 5.5)
        XCTAssertEqual(check.state, .tooQuiet)
        XCTAssertEqual(check.signalWarning, .tooQuiet, "reuses the HUD's assessment")
    }

    func testAQuietVoiceBelowTheSpeechBarIsStillTooQuiet() {
        var check = OnboardingMicrophoneCheck()
        _ = feed(&check, level: 0.3, from: 0, seconds: 6)
        XCTAssertEqual(check.state, .tooQuiet)
        XCTAssertNil(check.signalWarning, "audible, just not loud enough to count as speech")
    }

    func testClippingIsReportedAlongsideDetection() {
        var check = OnboardingMicrophoneCheck()
        _ = feed(&check, level: 0.9, peak: 1, from: 0, seconds: 2)
        XCTAssertEqual(check.state, .heardSpeech)
        XCTAssertEqual(check.signalWarning, .clipping)
    }

    func testALateBufferCannotStandInForSpeech() {
        var check = OnboardingMicrophoneCheck()
        check.ingest(level: 0.05, peak: 0.1, at: 0)
        check.ingest(level: 0.7, peak: 0.5, at: 3)
        XCTAssertEqual(check.state, .listening)
    }

    func testResetStartsOver() {
        var check = OnboardingMicrophoneCheck()
        _ = feed(&check, level: 0.6, from: 0, seconds: 1)
        check.reset()
        XCTAssertEqual(check.state, .listening)
        XCTAssertEqual(check.loudestLevel, 0)
    }

    func testBluetoothAndAirPodsAreFlagged() {
        XCTAssertEqual(MicrophoneInputAdvice.advice(transport: .bluetooth, name: "Headset"), .bluetoothLowQuality)
        XCTAssertEqual(MicrophoneInputAdvice.advice(transport: .other, name: "Jo’s AirPods Pro"), .bluetoothLowQuality)
        XCTAssertEqual(MicrophoneInputAdvice.advice(transport: .virtual, name: "BlackHole 2ch"), .virtualDevice)
        XCTAssertNil(MicrophoneInputAdvice.advice(transport: .builtIn, name: "MacBook Pro Microphone"))
        XCTAssertNil(MicrophoneInputAdvice.advice(transport: .usb, name: "Shure MV7"))
    }
}

final class GlobeKeyUsageTests: XCTestCase {
    func testStoredValuesMapToTheKeyboardSettingsChoices() {
        XCTAssertEqual(GlobeKeyUsage(storedValue: 0), .doNothing)
        XCTAssertEqual(GlobeKeyUsage(storedValue: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyUsage(storedValue: 2), .showEmojiAndSymbols)
        XCTAssertEqual(GlobeKeyUsage(storedValue: 3), .startDictation)
        XCTAssertEqual(GlobeKeyUsage(storedValue: nil), .systemDefault)
        XCTAssertEqual(GlobeKeyUsage(storedValue: 9), .unrecognized(9))
    }

    func testOnlyDoNothingIsFreeOfConflict() {
        XCTAssertFalse(GlobeKeyUsage.doNothing.conflictsWithShortcut)
        XCTAssertNil(GlobeKeyUsage.doNothing.conflictExplanation)
        for usage in [GlobeKeyUsage.changeInputSource, .showEmojiAndSymbols, .startDictation, .systemDefault, .unrecognized(7)] {
            XCTAssertTrue(usage.conflictsWithShortcut)
            XCTAssertTrue(usage.conflictExplanation?.contains("Do Nothing") == true)
        }
        XCTAssertTrue(GlobeKeyUsage.startDictation.conflictExplanation?.contains("Apple’s dictation") == true)
    }
}

final class StagedDownloadProgressTests: XCTestCase {
    func testRestartingOperationsAdvanceStagesInsteadOfRefilling() {
        var progress = StagedDownloadProgress(stageWeights: [1, 3])
        progress.ingest(fraction: 0, startsNewOperation: true)
        progress.ingest(fraction: 1)
        XCTAssertEqual(progress.overall, 0.25, accuracy: 0.001)
        progress.ingest(fraction: 0, startsNewOperation: true)
        XCTAssertEqual(progress.stage, 1)
        progress.ingest(fraction: 0.5)
        XCTAssertEqual(progress.overall, 0.625, accuracy: 0.001)
    }

    func testADroppingFractionAlsoMarksTheNextStage() {
        var progress = StagedDownloadProgress(stageWeights: [1, 1])
        progress.ingest(fraction: 0.9)
        progress.ingest(fraction: 0.1)
        XCTAssertEqual(progress.stage, 1)
        XCTAssertEqual(progress.overall, 0.55, accuracy: 0.001)
    }

    func testOverallIsMonotonicAndHeldBelowDoneUntilFinished() {
        var progress = StagedDownloadProgress(stageWeights: [1])
        progress.ingest(fraction: 0.6)
        progress.ingest(fraction: 0.58)
        XCTAssertEqual(progress.overall, 0.6, accuracy: 0.001)
        progress.ingest(fraction: 1)
        XCTAssertEqual(progress.overall, StagedDownloadProgress.unfinishedCeiling)
        progress.finish()
        XCTAssertEqual(progress.overall, 1)
        progress.ingest(fraction: 0, startsNewOperation: true)
        XCTAssertEqual(progress.overall, 1)
    }

    func testExtraOperationsStayOnTheLastStage() {
        var progress = StagedDownloadProgress(stageWeights: [1, 1])
        for _ in 0..<5 { progress.ingest(fraction: 0, startsNewOperation: true); progress.ingest(fraction: 1) }
        XCTAssertEqual(progress.stage, 1)
        XCTAssertLessThanOrEqual(progress.overall, StagedDownloadProgress.unfinishedCeiling)
    }

    func testParakeetEncoderDominatesTheFirstDownload() {
        var progress = StagedDownloadProgress.parakeetFirstDownload
        progress.ingest(fraction: 0, startsNewOperation: true)
        progress.ingest(fraction: 1)
        progress.ingest(fraction: 0, startsNewOperation: true)
        progress.ingest(fraction: 0.5)
        XCTAssertGreaterThan(progress.overall, 0.35)
        XCTAssertLessThan(progress.overall, 0.5)
    }

    func testDegenerateWeightsStillProduceAUsableTracker() {
        var progress = StagedDownloadProgress(stageWeights: [])
        progress.ingest(fraction: 0.5)
        XCTAssertEqual(progress.overall, 0.5, accuracy: 0.001)
    }
}

final class PracticeEvaluationTests: XCTestCase {
    func testSampleSentenceMatchesDespiteSmallDifferences() {
        XCTAssertEqual(PracticeEvaluation.evaluate(.sample, transcript: "Whisker flow turns what I say into text right where my cursor is."), .matched)
        XCTAssertEqual(PracticeEvaluation.evaluate(.sample, transcript: "Hello there."), .different)
    }

    func testSelfCorrectionIsRecognisedWhenOnlyTheRepairRemains() {
        XCTAssertEqual(PracticeEvaluation.evaluate(.selfCorrection, transcript: "Let's meet at 3."), .corrected)
        XCTAssertEqual(PracticeEvaluation.evaluate(.selfCorrection, transcript: "Let’s meet at three."), .corrected)
        XCTAssertEqual(PracticeEvaluation.evaluate(.selfCorrection, transcript: "Let's meet at 2, sorry, 3."), .notCorrected)
        XCTAssertEqual(PracticeEvaluation.evaluate(.selfCorrection, transcript: "Something else entirely."), .different)
    }

    /// The practice screen promises a demonstration; the shipped resolver must
    /// actually perform it on the words Parakeet produces for the prompt.
    func testTheShippedResolverPerformsTheDemonstratedCorrection() {
        for spoken in ["Let's meet at 2, sorry, 3.", "Let's meet at two, sorry, three."] {
            let resolved = SpokenSelfCorrection.resolve(spoken)
            XCTAssertEqual(PracticeEvaluation.evaluate(.selfCorrection, transcript: resolved), .corrected, resolved)
        }
    }
}

final class CaptureReadinessPolicyTests: XCTestCase {
    func testNoPreparedEngineOnBluetoothOrWirelessMicrophones() {
        XCTAssertFalse(CaptureReadinessPolicy.keepsEngineReady(transport: .bluetooth, name: "Jacob’s AirPods Pro"))
        XCTAssertFalse(CaptureReadinessPolicy.keepsEngineReady(transport: .bluetooth, name: "WH-1000XM5"),
                       "Any Bluetooth input, whatever it is called")
        XCTAssertFalse(CaptureReadinessPolicy.keepsEngineReady(transport: .wireless, name: "iPhone Microphone"))
        XCTAssertFalse(CaptureReadinessPolicy.keepsEngineReady(transport: .aggregate, name: "AirPods + Built-in"),
                       "A headset hidden behind an aggregate is recognised by name")
        XCTAssertFalse(CaptureReadinessPolicy.keepsEngineReady(transport: nil, name: "Unknown"), "Unknown transport: be safe")
    }

    func testWiredAndBuiltInMicrophonesKeepTheInstantStart() {
        XCTAssertTrue(CaptureReadinessPolicy.keepsEngineReady(transport: .builtIn, name: "MacBook Pro Microphone"))
        XCTAssertTrue(CaptureReadinessPolicy.keepsEngineReady(transport: .usb, name: "C920 HD Pro Webcam"))
        XCTAssertTrue(CaptureReadinessPolicy.keepsEngineReady(transport: .virtual, name: "Krisp Microphone"))
    }
}
