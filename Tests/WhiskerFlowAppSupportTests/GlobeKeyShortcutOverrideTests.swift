import XCTest
@testable import WhiskerFlowAppSupport
import WhiskerFlowCore

@MainActor
final class GlobeKeyShortcutOverrideTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "WhiskerFlow.GlobeOverrideTests.\(UUID().uuidString)"
        let domain = suite + ".keyboard"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            write(nil, domain: domain)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults, domain)
    }

    private func write(_ value: Int?, domain: String) {
        CFPreferencesSetAppValue(GlobeKeyUsage.defaultsKey as CFString, value.map { NSNumber(value: $0) }, domain as CFString)
        XCTAssertTrue(CFPreferencesAppSynchronize(domain as CFString))
    }

    private func read(_ domain: String) -> Int? {
        CFPreferencesAppSynchronize(domain as CFString)
        return (CFPreferencesCopyAppValue(GlobeKeyUsage.defaultsKey as CFString, domain as CFString) as? NSNumber)?.intValue
    }

    func testFnDisablesCompetingActionAndRestoresItWhenShortcutChanges() throws {
        try withPreferences { defaults, domain in
            write(3, domain: domain)
            let shortcut = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertEqual(read(domain), 0)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.rightOption.presetCombo!))
            XCTAssertEqual(read(domain), 3)
        }
    }

    func testQuitRestoresEveryOriginalActionIncludingAnUnsetPreference() throws {
        for original in [nil, 1, 2, 3, 99] as [Int?] {
            try withPreferences { defaults, domain in
                write(original, domain: domain)
                let shortcut = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
                XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
                XCTAssertEqual(read(domain), 0)
                XCTAssertTrue(shortcut.restore())
                XCTAssertEqual(read(domain), original)
            }
        }
    }

    func testRestartRetainsTheOriginalActionAndRepeatedConfigurationIsIdempotent() throws {
        try withPreferences { defaults, domain in
            write(2, domain: domain)
            let firstLaunch = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(firstLaunch.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertTrue(firstLaunch.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertEqual(read(domain), 0)
            let nextLaunch = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(nextLaunch.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertTrue(nextLaunch.restore())
            XCTAssertEqual(read(domain), 2)
        }
    }

    func testExternalPreferenceChangeIsPreservedOnQuit() throws {
        try withPreferences { defaults, domain in
            write(3, domain: domain)
            let shortcut = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            write(1, domain: domain)
            XCTAssertTrue(shortcut.restore())
            XCTAssertEqual(read(domain), 1)
        }
    }

    func testRestartWithAnotherShortcutRestoresAnInterruptedOverride() throws {
        try withPreferences { defaults, domain in
            write(3, domain: domain)
            let firstLaunch = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(firstLaunch.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            let nextLaunch = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(nextLaunch.update(shortcut: HotkeyTrigger.rightOption.presetCombo!))
            XCTAssertEqual(read(domain), 3)
        }
    }

    func testAReappliedOverrideRestoresTheLatestExternalChoice() throws {
        try withPreferences { defaults, domain in
            write(3, domain: domain)
            let shortcut = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            write(2, domain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertEqual(read(domain), 0)
            XCTAssertTrue(shortcut.restore())
            XCTAssertEqual(read(domain), 2)
        }
    }

    func testOtherShortcutsAndAnAlreadyDisabledSystemActionAreUntouched() throws {
        try withPreferences { defaults, domain in
            write(3, domain: domain)
            let shortcut = GlobeKeyShortcutOverride(defaults: defaults, preferencesDomain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.rightCommand.presetCombo!))
            XCTAssertEqual(read(domain), 3)
            write(0, domain: domain)
            XCTAssertTrue(shortcut.update(shortcut: HotkeyTrigger.fn.presetCombo!))
            XCTAssertTrue(shortcut.restore())
            XCTAssertEqual(read(domain), 0)
            write(2, domain: domain)
            XCTAssertTrue(shortcut.restore())
            XCTAssertEqual(read(domain), 2, "no backup may remain after an unneeded override")
        }
    }
}
