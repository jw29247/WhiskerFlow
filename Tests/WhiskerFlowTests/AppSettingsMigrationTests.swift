import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
final class AppSettingsMigrationTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "AppSettingsMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    private func settings(_ defaults: UserDefaults, _ name: String) -> AppSettings {
        AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
    }

    func testAutoDetectChosenAfterFreshInstallSurvivesRelaunch() {
        withDefaults { defaults, name in
            let first = settings(defaults, name)
            XCTAssertEqual(first.language, "en")
            first.language = "auto"

            XCTAssertEqual(settings(defaults, name).language, "auto")
        }
    }

    func testAutoDetectChosenAfterAnotherLanguageSurvivesRelaunch() {
        withDefaults { defaults, name in
            defaults.set("fr", forKey: "language")
            let first = settings(defaults, name)
            XCTAssertEqual(first.language, "fr")
            first.language = "auto"

            XCTAssertEqual(settings(defaults, name).language, "auto")
        }
    }

    func testLegacyStoredAutoStillMigratesOnce() {
        withDefaults { defaults, name in
            defaults.set("auto", forKey: "language")
            XCTAssertEqual(settings(defaults, name).language, "en")
        }
    }

    func testStoredWhisperEngineMovesToParakeetAndItsSettingsAreDropped() throws {
        #if !arch(arm64)
        throw XCTSkip("Parakeet only runs on Apple Silicon")
        #else
        for stored in ["whisperKit", "whisperCLI"] {
            withDefaults { defaults, name in
                defaults.set(stored, forKey: "engine")
                defaults.set("medium", forKey: "model")
                defaults.set("/opt/homebrew/bin/whisper", forKey: "whisperCommand")
                defaults.set(true, forKey: "dictionaryBiasWhisperKit")
                let migrated = settings(defaults, name)
                XCTAssertEqual(migrated.engine, .parakeetTDTv3)
                XCTAssertEqual(defaults.string(forKey: "engine"), "parakeetTDTv3")
                XCTAssertNil(defaults.object(forKey: "model"))
                XCTAssertNil(defaults.object(forKey: "whisperCommand"))
                XCTAssertNil(defaults.object(forKey: "dictionaryBiasWhisperKit"))
            }
        }
        #endif
    }

    func testAppleSpeechChoiceSurvivesRelaunch() {
        withDefaults { defaults, name in
            settings(defaults, name).engine = .appleSpeech
            XCTAssertEqual(settings(defaults, name).engine, .appleSpeech)
        }
    }

    func testFormattingCarriesDictationLanguage() {
        withDefaults { defaults, name in
            let first = settings(defaults, name)
            XCTAssertEqual(first.formatting.language, "en")
            first.language = "de"
            XCTAssertEqual(first.formatting.language, "de")
            XCTAssertEqual(settings(defaults, name).formatting.language, "de")
        }
    }
}
