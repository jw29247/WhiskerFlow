import XCTest
@testable import WhiskerFlowAppSupport

final class OnboardingFlowTests: XCTestCase {
    private let ready = OnboardingConditions(microphoneGranted: true, accessibilityGranted: true, modelReady: true)
    private let fresh = OnboardingConditions()

    func testSetupHasFourStepsInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.permissions, .microphone, .practice, .done])
        XCTAssertEqual(OnboardingStep.permissions.next, .microphone)
        XCTAssertEqual(OnboardingStep.microphone.next, .practice)
        XCTAssertEqual(OnboardingStep.practice.next, .done)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.permissions.previous)
    }

    func testBeginStartsAtPermissions() {
        var flow = OnboardingFlow()
        flow.begin(now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(flow.current, .permissions)
        XCTAssertTrue(flow.progress.isInProgress)
        XCTAssertEqual(flow.progress.startedAt, Date(timeIntervalSince1970: 10))
    }

    func testPermissionsGateContinueUntilBothAreGranted() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .permissions, startedAt: Date()))
        XCTAssertFalse(flow.canContinue(OnboardingConditions(microphoneGranted: true)))
        flow.advance(OnboardingConditions(microphoneGranted: true))
        XCTAssertEqual(flow.current, .permissions)
        XCTAssertFalse(flow.progress.completed.contains(.permissions))

        flow.advance(ready)
        XCTAssertEqual(flow.current, .microphone)
        XCTAssertTrue(flow.progress.completed.contains(.permissions))
        XCTAssertEqual(flow.progress.furthest, .microphone)
    }

    func testUnsatisfiedStepsAreSkippableAndRecordedAsSkipped() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .microphone, furthest: .microphone, startedAt: Date()))
        XCTAssertTrue(flow.canContinue(ready))
        flow.advance(ready)
        XCTAssertEqual(flow.current, .practice)
        XCTAssertTrue(flow.progress.skipped.contains(.microphone))
        XCTAssertFalse(flow.progress.completed.contains(.microphone))
    }

    func testTestedStepIsSatisfiedOnlyAfterItsCheckPasses() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .practice, furthest: .practice, startedAt: Date()))
        XCTAssertFalse(flow.isSatisfied(.practice, ready))
        flow.markPassed(.practice)
        flow.markPassed(.practice)
        XCTAssertTrue(flow.isSatisfied(.practice, ready))
        flow.advance(ready)
        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.progress.completed.contains(.practice))
        XCTAssertFalse(flow.progress.skipped.contains(.practice))
    }

    func testChangingWhatWasTestedRequiresTestingAgain() {
        var flow = OnboardingFlow()
        flow.markPassed(.microphone)
        flow.invalidate(.microphone)
        XCTAssertFalse(flow.isSatisfied(.microphone, ready))
        flow.markPassed(.microphone)
        XCTAssertTrue(flow.isSatisfied(.microphone, ready))
    }

    func testPassingAfterSkippingClearsTheSkip() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .practice, furthest: .practice, startedAt: Date()))
        flow.advance(ready)
        XCTAssertTrue(flow.progress.skipped.contains(.practice))
        flow.markPassed(.practice)
        XCTAssertFalse(flow.progress.skipped.contains(.practice))
    }

    func testMicrophoneCheckStopsCountingOnceAccessIsRevoked() {
        var flow = OnboardingFlow()
        flow.markPassed(.microphone)
        XCTAssertTrue(flow.isSatisfied(.microphone, ready))
        XCTAssertFalse(flow.isSatisfied(.microphone, OnboardingConditions(accessibilityGranted: true)))
    }

    func testPermissionsFollowLiveConditions() {
        let flow = OnboardingFlow()
        XCTAssertTrue(flow.isSatisfied(.permissions, ready))
        XCTAssertFalse(flow.isSatisfied(.permissions, fresh))
    }

    func testAdvancingFromPracticeReachesDoneAndFromDoneFinishes() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .practice, furthest: .practice, startedAt: Date()))
        flow.advance(ready)
        XCTAssertEqual(flow.current, .done)
        XCTAssertFalse(flow.progress.isFinished)
        flow.advance(ready, now: Date(timeIntervalSince1970: 99))
        XCTAssertFalse(flow.progress.skipped.contains(.done), "the last screen is finished, not skipped")
        XCTAssertTrue(flow.progress.isFinished)
        XCTAssertEqual(flow.progress.finishedAt, Date(timeIntervalSince1970: 99))
        flow.finish(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(flow.progress.finishedAt, Date(timeIntervalSince1970: 99), "finishing twice keeps the first finish")
    }

    func testJumpingIsLimitedToScreensAlreadyReached() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .permissions, furthest: .microphone, startedAt: Date()))
        XCTAssertTrue(flow.canJump(to: .permissions))
        XCTAssertTrue(flow.canJump(to: .microphone))
        XCTAssertFalse(flow.canJump(to: .practice))
        flow.jump(to: .practice)
        XCTAssertEqual(flow.current, .permissions)
        flow.jump(to: .microphone)
        XCTAssertEqual(flow.current, .microphone)
        flow.back()
        XCTAssertEqual(flow.current, .permissions)
        XCTAssertEqual(flow.progress.furthest, .microphone, "going back keeps the furthest screen")
    }

    func testResumeKeepsTheStepItStoppedOn() {
        let started = Date(timeIntervalSince1970: 5)
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .practice, furthest: .practice, startedAt: started))
        flow.begin()
        XCTAssertEqual(flow.current, .practice)
        XCTAssertEqual(flow.progress.startedAt, started)
    }

    func testDismissKeepsProgress() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .microphone, furthest: .microphone, startedAt: Date()))
        flow.dismiss()
        XCTAssertEqual(flow.current, .microphone)
        XCTAssertNotNil(flow.progress.dismissedAt)
        flow.begin()
        XCTAssertEqual(flow.current, .microphone)
        XCTAssertNil(flow.progress.dismissedAt, "resuming clears the dismissal")
    }

    func testRestartClearsEverything() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .done, furthest: .done, completed: [.practice],
                                                               startedAt: Date(), finishedAt: Date()))
        flow.restart()
        XCTAssertEqual(flow.current, .permissions)
        XCTAssertTrue(flow.progress.completed.isEmpty)
        XCTAssertTrue(flow.progress.isInProgress)
    }

    // MARK: - Launch policy

    func testNewInstallShowsSetup() {
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: nil, hasHistory: false, hadPreviousLaunch: false, permissionsReady: false), .show)
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: nil, hasHistory: false, hadPreviousLaunch: false, permissionsReady: true), .show)
    }

    func testExistingUsersWithHistoryAreNotShownSetupAgain() {
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: nil, hasHistory: true, hadPreviousLaunch: true, permissionsReady: false),
                       .skip(markFinished: true))
    }

    func testExistingUsersWithoutHistoryOnlySeeSetupWhenSomethingIsMissing() {
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: nil, hasHistory: false, hadPreviousLaunch: true, permissionsReady: true),
                       .skip(markFinished: true))
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: nil, hasHistory: false, hadPreviousLaunch: true, permissionsReady: false), .show)
    }

    func testQuittingMidwayResumesEvenAfterAPracticeDictationCreatedHistory() {
        let progress = OnboardingProgress(current: .practice, furthest: .practice, startedAt: Date())
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: progress, hasHistory: true, hadPreviousLaunch: true, permissionsReady: true), .show)
    }

    func testSetUpLaterIsRespectedOnlyOnceDictationCanWork() {
        let dismissed = OnboardingProgress(current: .microphone, furthest: .microphone, startedAt: Date(), dismissedAt: Date())
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: dismissed, hasHistory: false, hadPreviousLaunch: true, permissionsReady: true),
                       .skip(markFinished: false))
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: dismissed, hasHistory: false, hadPreviousLaunch: true, permissionsReady: false), .show)
    }

    func testFinishedSetupNeverReturnsAutomatically() {
        let progress = OnboardingProgress(current: .done, startedAt: Date(), finishedAt: Date())
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: progress, hasHistory: false, hadPreviousLaunch: true, permissionsReady: false),
                       .skip(markFinished: false))
    }

    func testRelaunchHintAppearsOnlyAfterAGrantAttemptThatDidNotTakeEffect() {
        let asked = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(OnboardingLaunchPolicy.suggestsAccessibilityRelaunch(requestedAt: nil, trusted: false, now: asked))
        XCTAssertFalse(OnboardingLaunchPolicy.suggestsAccessibilityRelaunch(requestedAt: asked, trusted: false, now: asked.addingTimeInterval(2)))
        XCTAssertTrue(OnboardingLaunchPolicy.suggestsAccessibilityRelaunch(requestedAt: asked, trusted: false, now: asked.addingTimeInterval(10)))
        XCTAssertFalse(OnboardingLaunchPolicy.suggestsAccessibilityRelaunch(requestedAt: asked, trusted: true, now: asked.addingTimeInterval(10)))
    }

    // MARK: - Persistence

    @MainActor
    func testProgressRoundTripsThroughUserDefaults() throws {
        let suite = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        XCTAssertNil(store.load())
        let progress = OnboardingProgress(current: .microphone, furthest: .practice, completed: [.permissions, .microphone],
                                          skipped: [.practice], startedAt: Date(timeIntervalSince1970: 5),
                                          dismissedAt: Date(timeIntervalSince1970: 6))
        store.save(progress)
        XCTAssertEqual(UserDefaultsOnboardingStore(defaults: defaults).load(), progress)
        store.clear()
        XCTAssertNil(store.load())
    }

    @MainActor
    func testCorruptStoredProgressIsTreatedAsAbsent() throws {
        let suite = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: UserDefaultsOnboardingStore.key)
        XCTAssertNil(UserDefaultsOnboardingStore(defaults: defaults).load())
    }

    // MARK: - Progress saved by earlier builds

    /// What builds with nine screens wrote: `current` and `furthest` as raw
    /// words, `completed` and `skipped` as arrays of them.
    private func legacyJSON(current: String, furthest: String? = nil, completed: [String] = [], skipped: [String] = [],
                            finished: Bool = false, dismissed: Bool = false) -> Data {
        var object: [String: Any] = [
            "current": current, "furthest": furthest ?? current,
            "completed": completed, "skipped": skipped,
            // JSONEncoder's default date form: seconds since 2001.
            "startedAt": 100.0,
        ]
        if finished { object["finishedAt"] = 200.0 }
        if dismissed { object["dismissedAt"] = 150.0 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) throws -> OnboardingProgress {
        try JSONDecoder().decode(OnboardingProgress.self, from: data)
    }

    func testEveryOldStepResumesAtTheNearestRemainingStepAfterIt() throws {
        let expected: [String: OnboardingStep] = [
            "welcome": .permissions, "permissions": .permissions, "microphone": .microphone,
            "shortcut": .practice, "language": .practice, "model": .practice,
            "practice": .practice, "extras": .done, "done": .done,
        ]
        for (old, step) in expected {
            XCTAssertEqual(OnboardingStep(storedValue: old), step, old)
            let progress = try decode(legacyJSON(current: old))
            XCTAssertEqual(progress.current, step, old)
            XCTAssertEqual(progress.furthest, step, old)
            XCTAssertTrue(progress.isInProgress, old)
            XCTAssertFalse(progress.isFinished, "\(old): part-way stays part-way")

            var flow = OnboardingFlow(progress: progress)
            flow.begin()
            XCTAssertEqual(flow.current, step, "\(old): resuming does not restart setup")
        }
        XCTAssertNil(OnboardingStep(storedValue: "nonsense"))
    }

    func testFinishedSetupStaysFinishedWhateverScreenItWasSavedOn() throws {
        for old in ["welcome", "shortcut", "language", "model", "extras", "done", "nonsense"] {
            let progress = try decode(legacyJSON(current: old, completed: ["welcome", "shortcut", "practice"], finished: true))
            XCTAssertTrue(progress.isFinished, old)
            XCTAssertEqual(progress.current, .done, old)
            XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: progress, hasHistory: false, hadPreviousLaunch: true,
                                                         permissionsReady: false), .skip(markFinished: false), old)
        }
    }

    func testChecksOnRemovedScreensAreDroppedAndTheRestKept() throws {
        let progress = try decode(legacyJSON(current: "model", furthest: "extras",
                                             completed: ["welcome", "permissions", "microphone", "shortcut", "language"],
                                             skipped: ["model", "practice"], dismissed: true))
        XCTAssertEqual(progress.current, .practice)
        XCTAssertEqual(progress.furthest, .done)
        XCTAssertEqual(progress.completed, [.permissions, .microphone])
        XCTAssertEqual(progress.skipped, [.practice])
        XCTAssertEqual(progress.dismissedAt, Date(timeIntervalSinceReferenceDate: 150))
        XCTAssertEqual(progress.startedAt, Date(timeIntervalSinceReferenceDate: 100))
    }

    func testAnUnknownStoredStepRestartsAtTheFirstScreenRatherThanFailing() throws {
        let progress = try decode(legacyJSON(current: "nonsense", furthest: "nonsense"))
        XCTAssertEqual(progress.current, .permissions)
        XCTAssertTrue(progress.isInProgress)
    }

    func testFurthestIsNeverBehindTheCurrentScreen() throws {
        let progress = try decode(legacyJSON(current: "extras", furthest: "welcome"))
        XCTAssertEqual(progress.current, .done)
        XCTAssertEqual(progress.furthest, .done)
    }

    @MainActor
    func testOldProgressInUserDefaultsLoadsMigrated() throws {
        let suite = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(legacyJSON(current: "language", completed: ["welcome", "permissions", "shortcut"]),
                     forKey: UserDefaultsOnboardingStore.key)
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.current, .practice)
        XCTAssertEqual(loaded.completed, [.permissions])
        // Saving writes only words this build knows, and reads back the same.
        store.save(loaded)
        XCTAssertEqual(store.load(), loaded)
    }
}
