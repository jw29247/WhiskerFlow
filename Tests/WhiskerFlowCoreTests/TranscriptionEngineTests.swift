import XCTest
@testable import WhiskerFlowCore

final class TranscriptionEngineTests: XCTestCase {
    func testParakeetTDTv3IsTheDefaultEngine() {
        XCTAssertEqual(TranscriptionEngineKind.defaultEngine, .parakeetTDTv3)
    }

    func testLegacyWhisperKitMediumDefaultMigratesToParakeet() {
        XCTAssertEqual(
            TranscriptionEngineKind.engineForStoredPreferences(
                engine: .whisperKit,
                model: .medium
            ),
            .parakeetTDTv3
        )
    }

    func testNonLegacyEnginePreferenceIsPreserved() {
        XCTAssertEqual(
            TranscriptionEngineKind.engineForStoredPreferences(
                engine: .appleSpeech,
                model: .medium
            ),
            .appleSpeech
        )
        XCTAssertEqual(
            TranscriptionEngineKind.engineForStoredPreferences(
                engine: .whisperKit,
                model: .small
            ),
            .whisperKit
        )
    }

    func testMigratedLegacyPreferenceCanRemainWhisperKitMediumWhenMigrationIsAlreadyComplete() {
        XCTAssertEqual(
            TranscriptionEngineKind.engineForStoredPreferences(
                engine: .whisperKit,
                model: .medium,
                migrateLegacyDefault: false
            ),
            .whisperKit
        )
    }
}
