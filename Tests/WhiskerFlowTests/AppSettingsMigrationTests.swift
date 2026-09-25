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

    func testWhisperKitMediumChosenAfterFreshInstallSurvivesRelaunch() {
        withDefaults { defaults, name in
            let first = settings(defaults, name)
            first.engine = .whisperKit
            first.model = .medium

            let relaunched = settings(defaults, name)
            XCTAssertEqual(relaunched.engine, .whisperKit)
            XCTAssertEqual(relaunched.model, .medium)
        }
    }

    func testLegacyWhisperKitMediumDefaultMigratesOnceOnAppleSilicon() throws {
        #if !arch(arm64)
        throw XCTSkip("Parakeet only runs on Apple Silicon")
        #else
        withDefaults { defaults, name in
            defaults.set(TranscriptionEngineKind.whisperKit.rawValue, forKey: "engine")
            defaults.set(WhisperModel.medium.rawValue, forKey: "model")
            let migrated = settings(defaults, name)
            XCTAssertEqual(migrated.engine, .parakeetTDTv3)

            migrated.engine = .whisperKit
            XCTAssertEqual(settings(defaults, name).engine, .whisperKit)
        }
        #endif
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
