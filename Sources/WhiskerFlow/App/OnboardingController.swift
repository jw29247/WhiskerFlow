import Foundation
import Observation
import WhiskerFlowAppSupport

/// Owns the setup flow for the app: persists every change so a quit resumes
/// on the same screen. Step logic lives in `OnboardingFlow`.
@MainActor
@Observable
final class OnboardingController {
    private(set) var flow: OnboardingFlow
    /// Drives the setup sheet on the main window.
    var isPresented = false
    /// When the user last asked macOS for Accessibility from setup.
    var accessibilityRequestedAt: Date?

    @ObservationIgnored private let store: any OnboardingProgressStoring

    init(store: any OnboardingProgressStoring) {
        self.store = store
        flow = OnboardingFlow(progress: store.load() ?? OnboardingProgress())
    }

    var current: OnboardingStep { flow.current }

    /// Launch-time decision. Returns whether the sheet should open.
    @discardableResult
    func presentIfNeeded(hasHistory: Bool, hadPreviousLaunch: Bool, permissionsReady: Bool) -> Bool {
        let decision = OnboardingLaunchPolicy.decide(
            progress: store.load(), hasHistory: hasHistory,
            hadPreviousLaunch: hadPreviousLaunch, permissionsReady: permissionsReady
        )
        switch decision {
        case .show:
            present()
            return true
        case .skip(let markFinished):
            // Recorded as done: this user never saw setup.
            if markFinished { apply { $0.finish() } }
            return false
        }
    }

    /// Opens setup where it left off (or from the start when it never ran or finished).
    func present() {
        if flow.progress.isFinished {
            apply { $0.restart() }
        } else {
            apply { $0.begin() }
        }
        isPresented = true
    }

    /// "Run setup again".
    func restart() {
        apply { $0.restart() }
        isPresented = true
    }

    func advance(_ conditions: OnboardingConditions) {
        let wasFinished = flow.progress.isFinished
        apply { $0.advance(conditions) }
        if !wasFinished && flow.progress.isFinished { isPresented = false }
    }

    func back() { apply { $0.back() } }
    func jump(to step: OnboardingStep) { apply { $0.jump(to: step) } }
    func markPassed(_ step: OnboardingStep) { apply { $0.markPassed(step) } }
    func invalidate(_ step: OnboardingStep) { apply { $0.invalidate(step) } }

    func finish() {
        apply { $0.finish() }
        isPresented = false
    }

    /// "Set up later".
    func dismiss() {
        apply { $0.dismiss() }
        isPresented = false
    }

    private func apply(_ change: (inout OnboardingFlow) -> Void) {
        var next = flow
        change(&next)
        if next != flow {
            flow = next
            store.save(next.progress)
        }
    }
}
