import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class OnboardingDefaultsTests: XCTestCase {
    // MARK: - Shortcut

    func testFnStaysWhenWhiskerFlowCanReserveIt() {
        XCTAssertNil(OnboardingDefaults.shortcut(current: .fn, personChoseShortcut: false, fnReservedForDictation: true))
    }

    func testFallsBackWhenMacOSKeepsTheGlobeKeyForItself() {
        XCTAssertEqual(OnboardingDefaults.shortcut(current: .fn, personChoseShortcut: false, fnReservedForDictation: false),
                       OnboardingDefaults.fallbackShortcut)
        XCTAssertNotEqual(OnboardingDefaults.fallbackShortcut, .fn)
    }

    func testAChosenShortcutIsNeverReplaced() {
        XCTAssertNil(OnboardingDefaults.shortcut(current: .fn, personChoseShortcut: true, fnReservedForDictation: false))
        XCTAssertNil(OnboardingDefaults.shortcut(current: .rightOption, personChoseShortcut: false, fnReservedForDictation: false))
    }

    // MARK: - Language

    func testANewInstallTakesTheFirstPreferredLanguageWhiskerFlowCanWrite() {
        XCTAssertEqual(OnboardingDefaults.initialLanguage(isFirstLaunch: true, preferredLanguages: ["es-MX", "en-GB"]), "es")
        XCTAssertEqual(OnboardingDefaults.initialLanguage(isFirstLaunch: true, preferredLanguages: ["tlh", "fr-FR"]), "fr")
        XCTAssertEqual(OnboardingDefaults.initialLanguage(isFirstLaunch: true, preferredLanguages: []), "en")
    }

    func testAnExistingInstallKeepsEnglish() {
        XCTAssertEqual(OnboardingDefaults.initialLanguage(isFirstLaunch: false, preferredLanguages: ["de-DE"]), "en")
    }
}
