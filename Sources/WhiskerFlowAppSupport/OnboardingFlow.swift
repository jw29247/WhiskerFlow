import Foundation

/// The first-run setup screens, in order. Raw values are the only thing
/// telemetry ever records about onboarding, so they must stay fixed words.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Comparable {
    case welcome, permissions, microphone, shortcut, language, model, practice, extras, done

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public var next: OnboardingStep? {
        let all = Self.allCases
        return index + 1 < all.count ? all[index + 1] : nil
    }

    public var previous: OnboardingStep? {
        index > 0 ? Self.allCases[index - 1] : nil
    }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .microphone: return "Microphone"
        case .shortcut: return "Shortcut"
        case .language: return "Language"
        case .model: return "Speech model"
        case .practice: return "Practice"
        case .extras: return "Extras"
        case .done: return "Done"
        }
    }

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.index < rhs.index }
}

/// Live facts the app reads from the system. Everything the user proves inside
/// setup (a heard voice, a fired shortcut, a practice dictation) lives in
/// `OnboardingProgress.completed` instead, so it survives a relaunch.
public struct OnboardingConditions: Equatable, Sendable {
    public var microphoneGranted: Bool
    public var accessibilityGranted: Bool
    public var modelReady: Bool
    public var atlasConnected: Bool
    public var meetingRecordingReady: Bool

    public init(
        microphoneGranted: Bool = false,
        accessibilityGranted: Bool = false,
        modelReady: Bool = false,
        atlasConnected: Bool = false,
        meetingRecordingReady: Bool = false
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
        self.modelReady = modelReady
        self.atlasConnected = atlasConnected
        self.meetingRecordingReady = meetingRecordingReady
    }

    public var permissionsReady: Bool { microphoneGranted && accessibilityGranted }
}

/// What is persisted between launches, so quitting mid-way resumes on the same screen.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public var current: OnboardingStep
    /// The furthest screen reached; progress dots up to here can be revisited.
    public var furthest: OnboardingStep
    /// Screens whose check passed or that the user acknowledged by continuing.
    public var completed: Set<OnboardingStep>
    public var skipped: Set<OnboardingStep>
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Set by "Set up later" (or closing the window); resuming clears it.
    public var dismissedAt: Date?

    public init(
        current: OnboardingStep = .welcome,
        furthest: OnboardingStep = .welcome,
        completed: Set<OnboardingStep> = [],
        skipped: Set<OnboardingStep> = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        dismissedAt: Date? = nil
    ) {
        self.current = current
        self.furthest = furthest
        self.completed = completed
        self.skipped = skipped
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dismissedAt = dismissedAt
    }

    public var isFinished: Bool { finishedAt != nil }
    public var isInProgress: Bool { startedAt != nil && finishedAt == nil }
}

public enum OnboardingOutcome: String, Sendable {
    case viewed, completed, skipped, dismissed, resumed, finished
}

/// One anonymous onboarding event: a fixed step name and a fixed outcome word.
/// It carries no content, device name, shortcut or transcript by construction.
public struct OnboardingTelemetryEvent: Equatable, Sendable {
    public let step: OnboardingStep
    public let outcome: OnboardingOutcome

    public init(step: OnboardingStep, outcome: OnboardingOutcome) {
        self.step = step
        self.outcome = outcome
    }

    /// Keys match `DiagnosticPrivacy`'s allow-list, so these values survive its filter.
    public var attributes: [String: String] { ["step": step.rawValue, "outcome": outcome.rawValue] }
}

/// The setup state machine: which screen is showing, which are satisfied, and
/// what moving between them records. The view owns no step logic of its own.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var progress: OnboardingProgress

    public init(progress: OnboardingProgress = OnboardingProgress()) {
        self.progress = progress
    }

    public var current: OnboardingStep { progress.current }

    /// Checks that setup can prove on its own; the rest come from the system.
    public static let testedSteps: Set<OnboardingStep> = [.microphone, .shortcut, .practice]

    public func isSatisfied(_ step: OnboardingStep, _ conditions: OnboardingConditions) -> Bool {
        switch step {
        case .welcome: return progress.completed.contains(.welcome)
        case .permissions: return conditions.permissionsReady
        // A heard voice is meaningless once access is revoked.
        case .microphone: return conditions.microphoneGranted && progress.completed.contains(.microphone)
        case .shortcut: return progress.completed.contains(.shortcut)
        // A language is always chosen (English unless changed), so Continue.
        case .language: return true
        case .model: return conditions.modelReady
        case .practice: return progress.completed.contains(.practice)
        case .extras: return conditions.atlasConnected && conditions.meetingRecordingReady
        case .done: return progress.isFinished
        }
    }

    /// Only permissions gate the way forward: without them nothing later can
    /// work. Every other screen can be skipped and revisited.
    public func canContinue(_ conditions: OnboardingConditions) -> Bool {
        current != .permissions || conditions.permissionsReady
    }

    public func canJump(to step: OnboardingStep) -> Bool {
        step <= progress.furthest
    }

    /// Starts (or resumes) a setup run. Returns the events to record.
    public mutating func begin(now: Date = Date()) -> [OnboardingTelemetryEvent] {
        if progress.isInProgress {
            progress.dismissedAt = nil
            return [OnboardingTelemetryEvent(step: current, outcome: .resumed)]
        }
        progress = OnboardingProgress(startedAt: now)
        return [OnboardingTelemetryEvent(step: .welcome, outcome: .viewed)]
    }

    /// Records that a screen's own check passed (a voice was heard, the shortcut
    /// fired, a practice dictation landed). Idempotent.
    public mutating func markPassed(_ step: OnboardingStep) -> [OnboardingTelemetryEvent] {
        guard progress.completed.insert(step).inserted else { return [] }
        progress.skipped.remove(step)
        return [OnboardingTelemetryEvent(step: step, outcome: .completed)]
    }

    /// A passed check no longer holds (e.g. the shortcut or microphone changed).
    public mutating func invalidate(_ step: OnboardingStep) {
        progress.completed.remove(step)
    }

    /// Continue, or Skip on an unsatisfied screen. Tested screens are recorded
    /// as completed the moment their check passes; an untested screen counts as
    /// completed when the user moves past it satisfied.
    public mutating func advance(_ conditions: OnboardingConditions, now: Date = Date()) -> [OnboardingTelemetryEvent] {
        guard canContinue(conditions) else { return [] }
        let step = current
        if step == .done { return finish(now: now) }
        var events: [OnboardingTelemetryEvent] = []
        if isSatisfied(step, conditions) || step == .welcome {
            if !Self.testedSteps.contains(step), progress.completed.insert(step).inserted {
                progress.skipped.remove(step)
                events.append(OnboardingTelemetryEvent(step: step, outcome: .completed))
            }
        } else if progress.skipped.insert(step).inserted {
            events.append(OnboardingTelemetryEvent(step: step, outcome: .skipped))
        }
        guard let next = step.next else { return events }
        move(to: next)
        events.append(OnboardingTelemetryEvent(step: next, outcome: .viewed))
        return events
    }

    public mutating func back() {
        guard let previous = current.previous else { return }
        progress.current = previous
    }

    public mutating func jump(to step: OnboardingStep) -> [OnboardingTelemetryEvent] {
        guard canJump(to: step), step != current else { return [] }
        progress.current = step
        return [OnboardingTelemetryEvent(step: step, outcome: .viewed)]
    }

    public mutating func finish(now: Date = Date()) -> [OnboardingTelemetryEvent] {
        guard !progress.isFinished else { return [] }
        progress.current = .done
        progress.furthest = .done
        progress.finishedAt = now
        return [OnboardingTelemetryEvent(step: .done, outcome: .finished)]
    }

    /// "Set up later": progress is kept so setup can resume where it stopped.
    public mutating func dismiss(now: Date = Date()) -> [OnboardingTelemetryEvent] {
        guard !progress.isFinished else { return [] }
        progress.dismissedAt = now
        return [OnboardingTelemetryEvent(step: current, outcome: .dismissed)]
    }

    /// "Run setup again" starts over from the welcome screen, keeping nothing.
    public mutating func restart(now: Date = Date()) -> [OnboardingTelemetryEvent] {
        progress = OnboardingProgress(startedAt: now)
        return [OnboardingTelemetryEvent(step: .welcome, outcome: .viewed)]
    }

    private mutating func move(to step: OnboardingStep) {
        progress.current = step
        if step > progress.furthest { progress.furthest = step }
    }
}

public enum OnboardingLaunchDecision: Equatable, Sendable {
    case show
    /// `markFinished`: an existing user who never saw this setup; record it as
    /// done so clearing history later does not bring it back.
    case skip(markFinished: Bool)
}

public enum OnboardingLaunchPolicy {
    public static func decide(
        progress: OnboardingProgress?,
        hasHistory: Bool,
        hadPreviousLaunch: Bool,
        permissionsReady: Bool
    ) -> OnboardingLaunchDecision {
        if let progress {
            if progress.isFinished { return .skip(markFinished: false) }
            // Quitting mid-way resumes; "Set up later" is respected once
            // dictation can work without it.
            if progress.isInProgress { return progress.dismissedAt != nil && permissionsReady ? .skip(markFinished: false) : .show }
        }
        if hasHistory { return .skip(markFinished: true) }
        if hadPreviousLaunch && permissionsReady { return .skip(markFinished: true) }
        return .show
    }

    /// After the user granted Accessibility in System Settings, macOS can keep
    /// reporting the process as untrusted until it is relaunched (notably when
    /// the grant was recorded against an earlier copy of the app).
    public static let relaunchHintDelay: TimeInterval = 6

    public static func suggestsAccessibilityRelaunch(
        requestedAt: Date?,
        trusted: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !trusted, let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) >= relaunchHintDelay
    }
}

@MainActor
public protocol OnboardingProgressStoring: AnyObject {
    func load() -> OnboardingProgress?
    func save(_ progress: OnboardingProgress)
    func clear()
}

@MainActor
public final class UserDefaultsOnboardingStore: OnboardingProgressStoring {
    public static let key = "onboardingProgress"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OnboardingProgress? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(OnboardingProgress.self, from: data)
    }

    public func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
