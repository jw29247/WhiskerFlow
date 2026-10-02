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

    func testBeginStartsAtWelcomeAndRecordsTheView() {
        var flow = OnboardingFlow()
        let events = flow.begin(now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(flow.current, .welcome)
        XCTAssertTrue(flow.progress.isInProgress)
        XCTAssertEqual(events, [OnboardingTelemetryEvent(step: .welcome, outcome: .viewed)])
    }

    func testPermissionsGateContinueUntilBothAreGranted() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .permissions, startedAt: Date()))
        XCTAssertFalse(flow.canContinue(OnboardingConditions(microphoneGranted: true)))
        XCTAssertEqual(flow.advance(OnboardingConditions(microphoneGranted: true)), [])
        XCTAssertEqual(flow.current, .permissions)

        let events = flow.advance(ready)
        XCTAssertEqual(flow.current, .microphone)
        XCTAssertEqual(events, [
            OnboardingTelemetryEvent(step: .permissions, outcome: .completed),
            OnboardingTelemetryEvent(step: .microphone, outcome: .viewed)
        ])
    }

    func testUnsatisfiedStepsAreSkippableAndRecordedAsSkipped() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .microphone, furthest: .microphone, startedAt: Date()))
        XCTAssertTrue(flow.canContinue(ready))
        let events = flow.advance(ready)
        XCTAssertEqual(flow.current, .shortcut)
        XCTAssertEqual(events.first, OnboardingTelemetryEvent(step: .microphone, outcome: .skipped))
        XCTAssertTrue(flow.progress.skipped.contains(.microphone))
    }

    func testTestedStepIsSatisfiedOnlyAfterItsCheckPasses() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .shortcut, startedAt: Date()))
        XCTAssertFalse(flow.isSatisfied(.shortcut, ready))
        XCTAssertEqual(flow.markPassed(.shortcut), [OnboardingTelemetryEvent(step: .shortcut, outcome: .completed)])
        XCTAssertEqual(flow.markPassed(.shortcut), [], "passing twice records once")
        XCTAssertTrue(flow.isSatisfied(.shortcut, ready))
        // Continuing from a passed tested step does not record a second completion.
        XCTAssertEqual(flow.advance(ready), [OnboardingTelemetryEvent(step: .language, outcome: .viewed)])
    }

    func testChangingWhatWasTestedRequiresTestingAgain() {
        var flow = OnboardingFlow()
        _ = flow.markPassed(.shortcut)
        flow.invalidate(.shortcut)
        XCTAssertFalse(flow.isSatisfied(.shortcut, ready))
        XCTAssertEqual(flow.markPassed(.shortcut), [OnboardingTelemetryEvent(step: .shortcut, outcome: .completed)])
    }

    func testPassingAfterSkippingClearsTheSkip() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .practice, furthest: .practice, startedAt: Date()))
        _ = flow.advance(ready)
        XCTAssertTrue(flow.progress.skipped.contains(.practice))
        _ = flow.markPassed(.practice)
        XCTAssertFalse(flow.progress.skipped.contains(.practice))
    }

    func testMicrophoneCheckStopsCountingOnceAccessIsRevoked() {
        var flow = OnboardingFlow()
        _ = flow.markPassed(.microphone)
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
        _ = flow.advance(ready)
        XCTAssertEqual(flow.current, .done)
        XCTAssertFalse(flow.progress.isFinished)
        let events = flow.advance(ready, now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(events, [OnboardingTelemetryEvent(step: .done, outcome: .finished)], "the last screen is finished, not skipped")
        XCTAssertFalse(flow.progress.skipped.contains(.done))
        XCTAssertTrue(flow.progress.isFinished)
        XCTAssertEqual(flow.finish(), [], "finishing twice records once")
    }

    func testJumpingIsLimitedToScreensAlreadyReached() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .model, startedAt: Date()))
        XCTAssertTrue(flow.canJump(to: .welcome))
        XCTAssertTrue(flow.canJump(to: .model))
        XCTAssertFalse(flow.canJump(to: .practice))
        XCTAssertEqual(flow.jump(to: .practice), [])
        XCTAssertEqual(flow.jump(to: .model), [OnboardingTelemetryEvent(step: .model, outcome: .viewed)])
        flow.back()
        XCTAssertEqual(flow.current, .language)
        XCTAssertEqual(flow.progress.furthest, .model, "going back keeps the furthest screen")
    }

    func testResumeReportsTheStepItStoppedOn() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .model, furthest: .model, startedAt: Date()))
        XCTAssertEqual(flow.begin(), [OnboardingTelemetryEvent(step: .model, outcome: .resumed)])
        XCTAssertEqual(flow.current, .model)
    }

    func testDismissRecordsDropOffWithoutLosingProgress() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .shortcut, furthest: .shortcut, startedAt: Date()))
        XCTAssertEqual(flow.dismiss(), [OnboardingTelemetryEvent(step: .shortcut, outcome: .dismissed)])
        XCTAssertEqual(flow.current, .shortcut)
        XCTAssertNotNil(flow.progress.dismissedAt)
        XCTAssertEqual(flow.begin(), [OnboardingTelemetryEvent(step: .shortcut, outcome: .resumed)])
        XCTAssertNil(flow.progress.dismissedAt, "resuming clears the dismissal")
    }

    func testRestartClearsEverything() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .done, furthest: .done, completed: [.shortcut],
                                                               startedAt: Date(), finishedAt: Date()))
        XCTAssertEqual(flow.restart(), [OnboardingTelemetryEvent(step: .welcome, outcome: .viewed)])
        XCTAssertEqual(flow.current, .welcome)
        XCTAssertTrue(flow.progress.completed.isEmpty)
        XCTAssertTrue(flow.progress.isInProgress)
    }

    func testTelemetryCarriesOnlyAllowListedFixedWords() {
        for step in OnboardingStep.allCases {
            let event = OnboardingTelemetryEvent(step: step, outcome: .completed)
            XCTAssertEqual(DiagnosticPrivacy.safeMetadata(from: event.attributes), event.attributes)
            XCTAssertEqual(Set(event.attributes.keys), ["step", "outcome"])
        }
        XCTAssertTrue(DiagnosticPrivacy.allowsBreadcrumb(category: "onboarding"))
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
