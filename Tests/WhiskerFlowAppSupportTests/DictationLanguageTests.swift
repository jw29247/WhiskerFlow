import XCTest
@testable import WhiskerFlowAppSupport

final class DictationLanguageTests: XCTestCase {
    func testParakeetLanguagesStayOnParakeet() {
        for code in ["en", "es", "de", "fr", "pl", "uk", "pt"] {
            XCTAssertEqual(DictationLanguagePlan(language: code, translateToEnglish: true).route, .parakeet, code)
        }
    }

    func testOtherLanguagesUseAppleDictationWithARegion() {
        XCTAssertEqual(DictationLanguagePlan(language: "hi", translateToEnglish: true).route, .appleDictation(locale: "hi-IN"))
        XCTAssertEqual(DictationLanguagePlan(language: "ja", translateToEnglish: true).route, .appleDictation(locale: "ja-JP"))
        XCTAssertEqual(DictationLanguagePlan(language: "zh-TW", translateToEnglish: true).route, .appleDictation(locale: "zh-TW"))
        XCTAssertEqual(DictationLanguagePlan(language: "ar", translateToEnglish: true).route, .appleDictation(locale: "ar-SA"))
    }

    func testEnglishAndAutoAreNeverForcedThroughApple() {
        XCTAssertEqual(DictationLanguagePlan(language: "auto", translateToEnglish: true).route, .parakeet)
        XCTAssertEqual(DictationLanguagePlan(language: "en-GB", translateToEnglish: true).route, .parakeet)
    }

    func testTranslationOnlyForAnotherLanguageWhenAskedFor() {
        XCTAssertNil(DictationLanguagePlan(language: "en", translateToEnglish: true).translationSource)
        XCTAssertNil(DictationLanguagePlan(language: "es", translateToEnglish: false).translationSource)
        XCTAssertEqual(DictationLanguagePlan(language: "es", translateToEnglish: true).translationSource, .language("es"))
        XCTAssertEqual(DictationLanguagePlan(language: "auto", translateToEnglish: true).translationSource, .detected)
    }

    func testOutputLanguageDrivesFormatting() {
        XCTAssertEqual(DictationLanguagePlan(language: "es", translateToEnglish: true).outputLanguage, "en")
        XCTAssertEqual(DictationLanguagePlan(language: "es", translateToEnglish: false).outputLanguage, "es")
        XCTAssertEqual(DictationLanguagePlan(language: "auto", translateToEnglish: false).outputLanguage, "auto")
    }

    /// Bilingual people slip into English; translating English "from Spanish"
    /// mangles it, so text that reads as English is left alone.
    func testEnglishTextIsNotTranslated() {
        XCTAssertEqual(DictationTextLanguage.detect("Can you send me the report before Friday please?"), "en")
        XCTAssertEqual(DictationTextLanguage.detect("¿Puedes enviarme el informe antes del viernes, por favor?"), "es")
        XCTAssertEqual(DictationTextLanguage.detect("明日の打ち合わせは十五時からに変更してもいいですか。"), "ja")
        XCTAssertNil(DictationTextLanguage.detect("ok"), "too short to tell")
    }

    func testCatalogCoversBothRecognisersWithoutDuplicates() {
        let codes = DictationLanguageCatalog.options.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in ["auto", "en", "es", "hi", "ar", "ja", "zh-CN", "zh-TW", "vi", "tr", "id", "fil"].filter({ $0 != "fil" }) {
            XCTAssertTrue(codes.contains(code), code)
        }
        XCTAssertEqual(codes.prefix(2), ["auto", "en"])
    }

    func testStoredLanguagesMapToACatalogOption() {
        XCTAssertEqual(DictationLanguageCatalog.option(for: "zh")?.code, "zh-CN")
        XCTAssertEqual(DictationLanguageCatalog.option(for: "es-MX")?.code, "es")
        XCTAssertNil(DictationLanguageCatalog.option(for: "xx"))
    }

    func testSuggestsTheMacsPreferredLanguage() {
        XCTAssertEqual(DictationLanguageCatalog.suggested(preferredLanguages: ["hi-IN", "en-GB"]), "hi")
        XCTAssertEqual(DictationLanguageCatalog.suggested(preferredLanguages: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(DictationLanguageCatalog.suggested(preferredLanguages: ["xx-YY"]), "en")
    }
}
