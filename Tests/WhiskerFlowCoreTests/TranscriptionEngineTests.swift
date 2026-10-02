import XCTest
@testable import WhiskerFlowCore

final class TranscriptionEngineTests: XCTestCase {
    func testParakeetTDTv3IsTheDefaultEngine() {
        XCTAssertEqual(TranscriptionEngineKind.defaultEngine, .parakeetTDTv3)
    }

    func testOnlyParakeetAndAppleSpeechAreOfferedInSettings() {
        XCTAssertEqual(TranscriptionEngineKind.selectableCases, [.parakeetTDTv3, .appleSpeech])
        XCTAssertEqual(TranscriptionEngineKind.engineForStoredPreferences(rawValue: "appleDictation"), .appleDictation)
    }

    func testStoredWhisperChoicesMoveToParakeet() {
        for stored in ["whisperKit", "whisperCLI", "something-new", nil] as [String?] {
            XCTAssertEqual(TranscriptionEngineKind.engineForStoredPreferences(rawValue: stored), .parakeetTDTv3)
        }
    }

    func testStoredRemainingEnginesArePreserved() {
        XCTAssertEqual(TranscriptionEngineKind.engineForStoredPreferences(rawValue: "appleSpeech"), .appleSpeech)
        XCTAssertEqual(TranscriptionEngineKind.engineForStoredPreferences(rawValue: "parakeetTDTv3"), .parakeetTDTv3)
    }

    func testHistoryRecordedWithARemovedEngineStillHasALabel() {
        XCTAssertEqual(TranscriptionEngineKind.displayName(forStored: "whisperKit"), "WhisperKit (removed)")
        XCTAssertEqual(TranscriptionEngineKind.displayName(forStored: "whisperCLI"), "Whisper CLI (removed)")
        XCTAssertEqual(TranscriptionEngineKind.displayName(forStored: "appleSpeech"), "Apple Speech (built-in)")
    }

    func testRecognizerHintsHaveNoWhisperSwitch() {
        let hints = RecognizerHints(terms: ["Atlas"], appleSpeech: true, parakeet: false)
        XCTAssertEqual(hints.terms(for: .appleSpeech), ["Atlas"])
        XCTAssertEqual(hints.terms(for: .parakeetTDTv3), [])
    }
}
