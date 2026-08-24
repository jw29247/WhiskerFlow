import XCTest
@testable import WhiskerFlowCore

final class TranscriptionEngineTests: XCTestCase {
    func testParakeetTDTv3IsTheDefaultEngine() {
        XCTAssertEqual(TranscriptionEngineKind.defaultEngine, .parakeetTDTv3)
    }

    func testParakeetTDTv3UsesBenefitLedDisplayCopy() {
        XCTAssertEqual(TranscriptionEngineKind.parakeetTDTv3.displayName, "Parakeet TDT v3 (on-device)")
        XCTAssertTrue(TranscriptionEngineKind.parakeetTDTv3.blurb.lowercased().contains("faster"))
        XCTAssertTrue(TranscriptionEngineKind.parakeetTDTv3.blurb.contains("accurate"))
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
