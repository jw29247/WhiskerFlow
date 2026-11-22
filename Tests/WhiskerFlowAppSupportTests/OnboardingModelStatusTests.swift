import XCTest
@testable import WhiskerFlowAppSupport

final class OnboardingModelStatusTests: XCTestCase {
    // MARK: - Model: starting

    func testSetupStartsTheModelOnlyWhenNothingIsRunning() {
        XCTAssertTrue(OnboardingModelPolicy.shouldStart(.notStarted, trigger: .setupOpened))
        XCTAssertTrue(OnboardingModelPolicy.shouldStart(.failed(.other), trigger: .setupOpened))
        for running: OnboardingModelPhase in [.downloading(fraction: 0.2), .loading, .optimising, .ready] {
            for trigger: OnboardingModelTrigger in [.setupOpened, .retry, .cameOnline] {
                XCTAssertFalse(OnboardingModelPolicy.shouldStart(running, trigger: trigger),
                               "\(running) \(trigger): a second download must never start")
            }
        }
    }

    func testRetryRestartsAnyFailure() {
        for failure: OnboardingModelFailure in [.offline, .notEnoughSpace(neededBytes: 2, availableBytes: 1), .other] {
            XCTAssertTrue(OnboardingModelPolicy.shouldStart(.failed(failure), trigger: .retry))
        }
    }

    func testReconnectingRetriesOnlyAnOfflineFailure() {
        XCTAssertTrue(OnboardingModelPolicy.shouldStart(.failed(.offline), trigger: .cameOnline))
        XCTAssertFalse(OnboardingModelPolicy.shouldStart(.failed(.notEnoughSpace(neededBytes: 2, availableBytes: 1)), trigger: .cameOnline))
        XCTAssertFalse(OnboardingModelPolicy.shouldStart(.failed(.other), trigger: .cameOnline))
    }

    // MARK: - Model: why it failed

    func testFailureIsExplainedFromWhatTheMacReports() {
        XCTAssertEqual(OnboardingModelFailure.classify(neededDownload: true, isOnline: false, availableBytes: 10, downloadBytes: 100), .offline)
        XCTAssertEqual(OnboardingModelFailure.classify(neededDownload: true, isOnline: true, availableBytes: 10, downloadBytes: 100),
                       .notEnoughSpace(neededBytes: 100, availableBytes: 10))
        XCTAssertEqual(OnboardingModelFailure.classify(neededDownload: true, isOnline: true, availableBytes: 500, downloadBytes: 100), .other)
        XCTAssertEqual(OnboardingModelFailure.classify(neededDownload: true, isOnline: true, availableBytes: nil, downloadBytes: 100), .other)
    }

    func testAModelAlreadyOnThisMacNeverBlamesTheNetworkOrDisk() {
        XCTAssertEqual(OnboardingModelFailure.classify(neededDownload: false, isOnline: false, availableBytes: 0, downloadBytes: 100), .other)
    }

    // MARK: - Practice readiness

    func testPractiseOpensOnlyOnceTheModelIsReady() {
        for phase: OnboardingModelPhase in [.notStarted, .downloading(fraction: 0.5), .loading, .optimising] {
            let readiness = OnboardingPracticeReadiness(phase: phase, fallbackAllowed: true)
            XCTAssertFalse(readiness.canPractise, "\(phase)")
            XCTAssertTrue(readiness.showsProgress, "\(phase)")
            XCTAssertFalse(readiness.offersRetry, "\(phase)")
            XCTAssertNotNil(readiness.headline, "\(phase)")
            XCTAssertEqual(readiness.detail, "This only happens once. Practice starts by itself when it’s ready.")
        }
        let ready = OnboardingPracticeReadiness(phase: .ready, fallbackAllowed: false)
        XCTAssertTrue(ready.canPractise)
        XCTAssertFalse(ready.showsProgress)
        XCTAssertNil(ready.headline)
        XCTAssertNil(ready.detail)
    }

    func testDownloadProgressIsShownAsAFractionAndClamped() {
        XCTAssertEqual(OnboardingPracticeReadiness(phase: .downloading(fraction: 0.42), fallbackAllowed: true).progressFraction, 0.42)
        XCTAssertEqual(OnboardingPracticeReadiness(phase: .downloading(fraction: 1.3), fallbackAllowed: true).progressFraction, 1)
        XCTAssertNil(OnboardingPracticeReadiness(phase: .loading, fallbackAllowed: true).progressFraction, "indeterminate")
    }

    func testAFailureSaysWhatHappenedAndOffersRetry() {
        let offline = OnboardingPracticeReadiness(phase: .failed(.offline), fallbackAllowed: false)
        XCTAssertFalse(offline.canPractise)
        XCTAssertTrue(offline.offersRetry)
        XCTAssertFalse(offline.showsProgress)
        XCTAssertEqual(offline.headline, "You’re offline, so the speech model can’t download.")
        XCTAssertEqual(offline.detail, "Connect to the internet. It tries again by itself, or choose Retry.")

        let full = OnboardingPracticeReadiness(phase: .failed(.notEnoughSpace(neededBytes: 650_000_000, availableBytes: 210_000_000)),
                                               fallbackAllowed: false)
        XCTAssertEqual(full.headline, "There isn’t enough free space for the speech model.")
        XCTAssertTrue(full.detail?.contains("650") == true && full.detail?.contains("210") == true, full.detail ?? "")
        XCTAssertTrue(full.detail?.hasSuffix("Free up some space, then choose Retry.") == true)

        let other = OnboardingPracticeReadiness(phase: .failed(.other), fallbackAllowed: false)
        XCTAssertEqual(other.headline, "The speech model didn’t load.")
    }

    func testWithTheAppleFallbackOnAFailureStillLetsThePersonPractise() {
        let readiness = OnboardingPracticeReadiness(phase: .failed(.offline), fallbackAllowed: true)
        XCTAssertTrue(readiness.canPractise)
        XCTAssertTrue(readiness.offersRetry)
        XCTAssertTrue(readiness.detail?.hasSuffix("Until then, you can practise with Apple’s speech recognition.") == true)
    }

    /// A retry after a failure goes back to preparing, so practice closes
    /// again until the model is ready, then opens by itself.
    func testRetryWalksBackThroughPreparingToReady() {
        let sequence: [(OnboardingModelPhase, Bool)] = [
            (.failed(.offline), false), (.downloading(fraction: 0), false), (.downloading(fraction: 0.9), false),
            (.optimising, false), (.ready, true),
        ]
        for (phase, canPractise) in sequence {
            XCTAssertEqual(OnboardingPracticeReadiness(phase: phase, fallbackAllowed: false).canPractise, canPractise, "\(phase)")
        }
        XCTAssertTrue(OnboardingModelPolicy.shouldStart(.failed(.offline), trigger: .retry))
        XCTAssertFalse(OnboardingModelPolicy.shouldStart(.downloading(fraction: 0), trigger: .retry), "a second Retry while it runs does nothing")
    }
}
