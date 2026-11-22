import XCTest
@testable import WhiskerFlowAppSupport

final class OnboardingFlowTests: XCTestCase {
    private let ready = OnboardingConditions(microphoneGranted: true, accessibilityGranted: true, modelReady: true)
    private let fresh = OnboardingConditions()

    func testStepsRunInTheSpecifiedOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .permissions, .microphone, .shortcut, .language, .model, .practice, .extras, .done])
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
    }

    func testBeginStartsAtWelcome() {
        var flow = OnboardingFlow()
        flow.begin(now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(flow.current, .welcome)
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
        XCTAssertEqual(flow.current, .shortcut)
        XCTAssertTrue(flow.progress.skipped.contains(.microphone))
        XCTAssertFalse(flow.progress.completed.contains(.microphone))
    }

    func testTestedStepIsSatisfiedOnlyAfterItsCheckPasses() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .shortcut, startedAt: Date()))
        XCTAssertFalse(flow.isSatisfied(.shortcut, ready))
        flow.markPassed(.shortcut)
        flow.markPassed(.shortcut)
        XCTAssertTrue(flow.isSatisfied(.shortcut, ready))
        flow.advance(ready)
        XCTAssertEqual(flow.current, .language)
        XCTAssertTrue(flow.progress.completed.contains(.shortcut))
        XCTAssertFalse(flow.progress.skipped.contains(.shortcut))
    }

    func testChangingWhatWasTestedRequiresTestingAgain() {
        var flow = OnboardingFlow()
        flow.markPassed(.shortcut)
        flow.invalidate(.shortcut)
        XCTAssertFalse(flow.isSatisfied(.shortcut, ready))
        flow.markPassed(.shortcut)
        XCTAssertTrue(flow.isSatisfied(.shortcut, ready))
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

    func testSystemBackedStepsFollowLiveConditions() {
        let flow = OnboardingFlow()
        XCTAssertTrue(flow.isSatisfied(.model, ready))
        XCTAssertFalse(flow.isSatisfied(.model, fresh))
        XCTAssertFalse(flow.isSatisfied(.extras, ready))
        XCTAssertTrue(flow.isSatisfied(.extras, OnboardingConditions(atlasConnected: true, meetingRecordingReady: true)))
    }

    func testAdvancingFromExtrasReachesDoneAndFromDoneFinishes() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .extras, furthest: .extras, startedAt: Date()))
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
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .model, startedAt: Date()))
        XCTAssertTrue(flow.canJump(to: .welcome))
        XCTAssertTrue(flow.canJump(to: .model))
        XCTAssertFalse(flow.canJump(to: .practice))
        flow.jump(to: .practice)
        XCTAssertEqual(flow.current, .shortcut)
        flow.jump(to: .model)
        XCTAssertEqual(flow.current, .model)
        flow.back()
        XCTAssertEqual(flow.current, .language)
        XCTAssertEqual(flow.progress.furthest, .model, "going back keeps the furthest screen")
    }

    func testResumeKeepsTheStepItStoppedOn() {
        let started = Date(timeIntervalSince1970: 5)
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .model, furthest: .model, startedAt: started))
        flow.begin()
        XCTAssertEqual(flow.current, .model)
        XCTAssertEqual(flow.progress.startedAt, started)
    }

    func testDismissKeepsProgress() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .shortcut, startedAt: Date()))
        flow.dismiss()
        XCTAssertEqual(flow.current, .shortcut)
        XCTAssertNotNil(flow.progress.dismissedAt)
        flow.begin()
        XCTAssertEqual(flow.current, .shortcut)
        XCTAssertNil(flow.progress.dismissedAt, "resuming clears the dismissal")
    }

    func testRestartClearsEverything() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .done, furthest: .done, completed: [.shortcut],
                                                               startedAt: Date(), finishedAt: Date()))
        flow.restart()
        XCTAssertEqual(flow.current, .welcome)
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
        let progress = OnboardingProgress(current: .extras, furthest: .extras, startedAt: Date())
        XCTAssertEqual(OnboardingLaunchPolicy.decide(progress: progress, hasHistory: true, hadPreviousLaunch: true, permissionsReady: true), .show)
    }

    func testSetUpLaterIsRespectedOnlyOnceDictationCanWork() {
        let dismissed = OnboardingProgress(current: .shortcut, furthest: .shortcut, startedAt: Date(), dismissedAt: Date())
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
        let progress = OnboardingProgress(current: .model, furthest: .practice, completed: [.welcome, .microphone],
                                          skipped: [.shortcut], startedAt: Date(timeIntervalSince1970: 5))
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
}
