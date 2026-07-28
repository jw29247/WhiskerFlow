import XCTest
@testable import WhiskerFlowCore

final class WhisperModelTests: XCTestCase {
    func testEnglishUsesEnglishOnlyIdentifier() {
        for model in WhisperModel.allCases {
            XCTAssertEqual(
                model.whisperKitIdentifier(multilingual: false),
                "openai_whisper-\(model.rawValue).en"
            )
        }
    }

    func testMultilingualDropsTheEnglishOnlySuffix() {
        for model in WhisperModel.allCases {
            XCTAssertEqual(
                model.whisperKitIdentifier(multilingual: true),
                "openai_whisper-\(model.rawValue)"
            )
        }
    }

    func testEnglishLanguagesResolveToTheEnglishOnlyModel() {
        for language in ["en", "EN", "en-GB", "en-US", "en_US"] {
            XCTAssertFalse(
                WhisperModel.requiresMultilingualModel(language: language),
                "\(language) should stay on the English-only model"
            )
            XCTAssertEqual(
                WhisperModel.tiny.whisperKitIdentifier(
                    multilingual: WhisperModel.requiresMultilingualModel(language: language)
                ),
                "openai_whisper-tiny.en"
            )
        }
    }

    func testOtherLanguagesAndAutoDetectResolveToTheMultilingualModel() {
        for language in ["es", "fr", "ja", "pt-BR", "auto"] {
            XCTAssertTrue(
                WhisperModel.requiresMultilingualModel(language: language),
                "\(language) needs the multilingual model"
            )
            XCTAssertEqual(
                WhisperModel.small.whisperKitIdentifier(
                    multilingual: WhisperModel.requiresMultilingualModel(language: language)
                ),
                "openai_whisper-small"
            )
        }

        XCTAssertTrue(WhisperModel.requiresMultilingualModel(language: nil))
        XCTAssertTrue(WhisperModel.requiresMultilingualModel(language: ""))
        XCTAssertEqual(
            WhisperModel.medium.whisperKitIdentifier(
                multilingual: WhisperModel.requiresMultilingualModel(language: nil)
            ),
            "openai_whisper-medium"
        )
    }
}
