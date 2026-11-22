import XCTest
@testable import WhiskerFlowCore

final class ShortcutEventFilterTests: XCTestCase {
    private let f5: UInt16 = 96
    private let space: UInt16 = 49
    private let escape: UInt16 = 53
    private let rKey: UInt16 = 15
    private let aKey: UInt16 = 0
    private let fnKey: UInt16 = 63
    private let leftOption: UInt16 = 58
    private let meeting = KeyCombo(keyCode: 15, modifiers: [.command, .option, .shift])
    private let fn = KeyCombo(keyCode: 63, modifiers: .function, isModifierOnly: true)

    private func down(_ filter: inout ShortcutEventFilter, _ key: UInt16, _ mods: KeyModifiers = [],
                      repeat isRepeat: Bool = false) -> ShortcutEventFilter.Decision {
        filter.decide(kind: .keyDown, keyCode: key, modifiers: mods, isRepeat: isRepeat)
    }

    private func up(_ filter: inout ShortcutEventFilter, _ key: UInt16, _ mods: KeyModifiers = []) -> ShortcutEventFilter.Decision {
        filter.decide(kind: .keyUp, keyCode: key, modifiers: mods, isRepeat: false)
    }

    // MARK: - Function-key and combination dictation shortcuts

    func testFunctionKeyShortcutIsSwallowedWithItsRepeatsAndRelease() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: f5))
        XCTAssertEqual(down(&filter, f5), .init(consume: true, forwardToDictation: true))
        XCTAssertEqual(down(&filter, f5, repeat: true), .init(consume: true, forwardToDictation: true))
        XCTAssertEqual(up(&filter, f5), .init(consume: true, forwardToDictation: true))
    }

    func testCombinationShortcutIsSwallowedEvenWhenModifiersAreReleasedFirst() {
        let combo = KeyCombo(keyCode: space, modifiers: [.control, .option])
        var filter = ShortcutEventFilter(dictationCombo: combo)
        XCTAssertTrue(down(&filter, space, [.control, .option]).consume)
        // The modifier change is fed to the matcher (it releases on modifier up) but never swallowed.
        XCTAssertEqual(filter.decide(kind: .flagsChanged, keyCode: leftOption, modifiers: .control, isRepeat: false),
                       .init(forwardToDictation: true))
        XCTAssertTrue(up(&filter, space).consume, "The release of a swallowed press is swallowed too")
    }

    func testOtherKeysAndOtherModifierChordsPassThrough() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: space, modifiers: [.control, .option]))
        // Plain Space, and ⌃⌥⇧Space, are typing or another app's shortcut.
        XCTAssertEqual(down(&filter, space), .init(forwardToDictation: true))
        XCTAssertFalse(up(&filter, space).consume)
        XCTAssertFalse(down(&filter, space, [.control, .option, .shift]).consume)
        XCTAssertFalse(up(&filter, space).consume)
        XCTAssertEqual(down(&filter, aKey), .pass)
        XCTAssertEqual(up(&filter, aKey), .pass)
    }

    func testF5WithAModifierIsNotTheF5Shortcut() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: f5))
        XCTAssertFalse(down(&filter, f5, .command).consume)
        XCTAssertFalse(up(&filter, f5, .command).consume)
        // fn, which macOS sets on function keys, does not count as a modifier.
        XCTAssertTrue(down(&filter, f5, .function).consume)
    }

    func testAStrayReleaseWithoutASwallowedPressPasses() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: f5))
        XCTAssertFalse(up(&filter, f5).consume)
        XCTAssertFalse(down(&filter, f5, repeat: true).consume)
    }

    // MARK: - fn/Globe

    func testModifierOnlyShortcutIsNeverHandledByTheTap() {
        var filter = ShortcutEventFilter(dictationCombo: fn, meetingCombo: meeting)
        XCTAssertNil(filter.dictationCombo)
        XCTAssertFalse(filter.needsFlagsChanged, "fn/Globe must not pass through the tap at all")
        XCTAssertEqual(filter.decide(kind: .flagsChanged, keyCode: fnKey, modifiers: .function, isRepeat: false), .pass)
        XCTAssertEqual(down(&filter, aKey, .function), .pass)
    }

    // MARK: - Esc

    func testEscapeIsSwallowedOnlyWhileADictationIsRecording() {
        var filter = ShortcutEventFilter(dictationCombo: fn, meetingCombo: meeting)
        XCTAssertEqual(down(&filter, escape), .pass, "Esc with no dictation closes the front app's dialog as usual")
        XCTAssertEqual(up(&filter, escape), .pass)

        filter.isDictationRecording = true
        XCTAssertEqual(down(&filter, escape), .init(consume: true, discard: true))
        XCTAssertEqual(down(&filter, escape, repeat: true), .init(consume: true))
        filter.isDictationRecording = false
        XCTAssertTrue(up(&filter, escape).consume, "The release follows its press even after the dictation ended")
        XCTAssertEqual(down(&filter, escape), .pass)
    }

    func testEscapeWithModifiersIsNotADiscard() {
        var filter = ShortcutEventFilter()
        filter.isDictationRecording = true
        XCTAssertEqual(down(&filter, escape, .option), .pass)
        XCTAssertEqual(down(&filter, escape, .command), .pass)
    }

    // MARK: - Meeting shortcut

    func testMeetingShortcutIsSwallowedAndToggles() {
        var filter = ShortcutEventFilter(dictationCombo: fn, meetingCombo: meeting)
        XCTAssertEqual(down(&filter, rKey, [.command, .option, .shift]), .init(consume: true, toggleMeeting: true))
        XCTAssertEqual(down(&filter, rKey, [.command, .option, .shift], repeat: true), .init(consume: true),
                       "Holding the keys toggles once")
        XCTAssertEqual(up(&filter, rKey, [.command, .option, .shift]), .init(consume: true))
        XCTAssertEqual(down(&filter, rKey), .pass, "Typing r is untouched")
        XCTAssertEqual(down(&filter, rKey, [.command, .shift]), .pass)
    }

    func testDictationShortcutWinsWhenItEqualsTheMeetingShortcut() {
        var filter = ShortcutEventFilter(dictationCombo: meeting, meetingCombo: meeting)
        XCTAssertEqual(down(&filter, rKey, [.command, .option, .shift]), .init(consume: true, forwardToDictation: true))
    }

    // MARK: - Suspension and installation

    func testEverythingPassesWhileTheShortcutIsSuspended() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: f5), meetingCombo: meeting)
        filter.isDictationRecording = true
        filter.isSuspended = true
        XCTAssertEqual(down(&filter, f5), .pass)
        XCTAssertEqual(down(&filter, escape), .pass)
        XCTAssertEqual(down(&filter, rKey, [.command, .option, .shift]), .pass)
        XCTAssertEqual(filter.decide(kind: .flagsChanged, keyCode: leftOption, modifiers: .option, isRepeat: false), .pass)
    }

    func testSuspendingMidPressLetsTheReleaseThrough() {
        var filter = ShortcutEventFilter(dictationCombo: KeyCombo(keyCode: f5))
        XCTAssertTrue(down(&filter, f5).consume)
        filter.isSuspended = true
        XCTAssertEqual(up(&filter, f5), .pass)
        filter.isSuspended = false
        XCTAssertFalse(up(&filter, f5).consume, "No stale state survives a suspension")
    }

    func testTapIsNeededOnlyWhileACaseCanApply() {
        var filter = ShortcutEventFilter(dictationCombo: fn)
        XCTAssertFalse(filter.needsTap)
        filter.isDictationRecording = true
        XCTAssertTrue(filter.needsTap)
        XCTAssertFalse(filter.needsFlagsChanged)
        filter.isDictationRecording = false
        filter.setDictationCombo(KeyCombo(keyCode: f5))
        XCTAssertTrue(filter.needsTap)
        XCTAssertTrue(filter.needsFlagsChanged)
        filter.setDictationCombo(fn)
        filter.meetingCombo = meeting
        XCTAssertTrue(filter.needsTap)
        XCTAssertFalse(filter.needsFlagsChanged)
    }
}
