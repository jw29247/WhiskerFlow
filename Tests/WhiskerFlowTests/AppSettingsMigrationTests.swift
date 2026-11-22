import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
final class AppSettingsMigrationTests: XCTestCase {
    func testCleanupIsOptInAndKeepsTheUsersChoice() {
        withDefaults { defaults, name in
            let initial = settings(defaults, name)
            XCTAssertFalse(initial.cleanupEnabled)
            initial.cleanupEnabled = true
            XCTAssertTrue(settings(defaults, name).cleanupEnabled)
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "AppSettingsMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    private func settings(_ defaults: UserDefaults, _ name: String) -> AppSettings {
        AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
    }

    func testAutomaticMeetingRecordingIsOffOnAFreshInstallAndNotAsked() {
        withDefaults { defaults, name in
            let fresh = settings(defaults, name)
            XCTAssertFalse(fresh.meetingModeEnabled)
            XCTAssertFalse(fresh.meetingModeChoicePending)
            XCTAssertFalse(settings(defaults, name).meetingModeChoicePending, "a relaunch")
        }
    }

    /// 2.0.0 to 2.1.0 switched automatic recording on for every install.
    func testAnEarlierOnResetsToOffOnceAndAsks() {
        withDefaults { defaults, name in
            defaults.set(true, forKey: "meetingModeEnabled")
            defaults.set(true, forKey: "meetingModeDefaultOnMigrated")
            let upgraded = settings(defaults, name)
            XCTAssertFalse(upgraded.meetingModeEnabled)
            XCTAssertTrue(upgraded.meetingModeChoicePending)
            XCTAssertNil(defaults.object(forKey: "meetingModeDefaultOnMigrated"))

            let relaunched = settings(defaults, name)
            XCTAssertFalse(relaunched.meetingModeEnabled)
            XCTAssertTrue(relaunched.meetingModeChoicePending, "still asked until answered")
        }
    }

    func testAnEarlierOffStaysOffAndIsNotAsked() {
        withDefaults { defaults, name in
            defaults.set(false, forKey: "meetingModeEnabled")
            let upgraded = settings(defaults, name)
            XCTAssertFalse(upgraded.meetingModeEnabled)
            XCTAssertFalse(upgraded.meetingModeChoicePending)
        }
    }

    func testAnsweringTheQuestionIsKeptAcrossRelaunches() {
        for answer in [false, true] {
            withDefaults { defaults, name in
                defaults.set(true, forKey: "meetingModeEnabled")
                let upgraded = settings(defaults, name)
                upgraded.answerMeetingModeChoice(enabled: answer)
                XCTAssertFalse(upgraded.meetingModeChoicePending)
                XCTAssertEqual(upgraded.meetingModeEnabled, answer)

                let relaunched = settings(defaults, name)
                XCTAssertFalse(relaunched.meetingModeChoicePending, "not asked again")
                XCTAssertEqual(relaunched.meetingModeEnabled, answer, "not reset again")
            }
        }
    }

    func testALaterChoiceSurvivesRelaunch() {
        withDefaults { defaults, name in
            settings(defaults, name).meetingModeEnabled = true
            let relaunched = settings(defaults, name)
            XCTAssertTrue(relaunched.meetingModeEnabled)
            XCTAssertFalse(relaunched.meetingModeChoicePending)
            relaunched.meetingModeEnabled = false
            XCTAssertFalse(settings(defaults, name).meetingModeEnabled)
        }
    }

    func testChangingTheToggleWhilePendingAnswersTheQuestion() {
        withDefaults { defaults, name in
            defaults.set(true, forKey: "meetingModeEnabled")
            let upgraded = settings(defaults, name)
            upgraded.meetingModeEnabled = true
            XCTAssertFalse(upgraded.meetingModeChoicePending)

            let relaunched = settings(defaults, name)
            XCTAssertTrue(relaunched.meetingModeEnabled)
            XCTAssertFalse(relaunched.meetingModeChoicePending)
        }
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

    /// 0.8.x wrote `languageAutoMigrated` only when migrating "auto", so an
    /// upgrade is recognised from what those builds did leave behind.
    func testUpgradeFromAnEarlierBuildCountsAsAPreviousLaunch() {
        withDefaults { defaults, name in
            XCTAssertFalse(settings(defaults, name).hadPreviousLaunch, "A fresh install")
            XCTAssertTrue(settings(defaults, name).hadPreviousLaunch, "Its second launch")
        }
        for marker in ["SUHasLaunchedBefore", "hotkey"] {
            withDefaults { defaults, name in
                defaults.set(marker == "hotkey" ? "rightOption" : true, forKey: marker)
                XCTAssertTrue(settings(defaults, name).hadPreviousLaunch, marker)
            }
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

    /// Builds up to 2.1.1 stored a persistent ID to tag diagnostics sent off the Mac.
    func testStoredInstallationIDIsDeletedAtLaunch() {
        withDefaults { defaults, name in
            defaults.set(UUID().uuidString, forKey: "diagnostics.installationID")
            _ = settings(defaults, name)
            XCTAssertNil(defaults.object(forKey: "diagnostics.installationID"))
        }
    }
}
