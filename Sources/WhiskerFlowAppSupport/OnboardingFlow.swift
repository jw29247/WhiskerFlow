import Foundation

/// The first-run setup screens, in order. Raw values are persisted with the
/// saved setup progress, so they must stay fixed words.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Comparable {
    case permissions, microphone, practice, done

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
        case .permissions: return "Permissions"
        case .microphone: return "Microphone"
        case .practice: return "Practice"
        case .done: return "Done"
        }
    }

    /// Reads a stored raw value, including the screens earlier builds had.
    /// A removed screen resumes at the nearest remaining screen after it:
    /// welcome → permissions; shortcut, language and model → practice;
    /// extras → done. Nil only for a word no build ever wrote.
    public init?(storedValue: String) {
        if let step = OnboardingStep(rawValue: storedValue) {
            self = step
            return
        }
        switch storedValue {
        case "welcome": self = .permissions
        case "shortcut", "language", "model": self = .practice
        case "extras": self = .done
        default: return nil
        }
    }

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.index < rhs.index }
}

/// Live facts the app reads from the system. Everything the user proves inside
/// setup (a heard voice, a practice dictation) lives in
/// `OnboardingProgress.completed` instead, so it survives a relaunch.
public struct OnboardingConditions: Equatable, Sendable {
    public var microphoneGranted: Bool
    public var accessibilityGranted: Bool
    public var modelReady: Bool

    public init(
        microphoneGranted: Bool = false,
        accessibilityGranted: Bool = false,
        modelReady: Bool = false
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
        self.modelReady = modelReady
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
        current: OnboardingStep = .permissions,
        furthest: OnboardingStep = .permissions,
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

    private enum CodingKeys: String, CodingKey {
        case current, furthest, completed, skipped, startedAt, finishedAt, dismissedAt
    }

    /// Progress saved by an earlier build may name screens that no longer
    /// exist. Those map forward (`OnboardingStep(storedValue:)`), checks
    /// recorded on removed screens are dropped, and a finished setup stays
    /// finished whatever screen it was saved on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        let finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        let dismissedAt = try container.decodeIfPresent(Date.self, forKey: .dismissedAt)
        func step(_ key: CodingKeys) -> OnboardingStep? {
            (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(OnboardingStep.init(storedValue:))
        }
        func steps(_ key: CodingKeys) -> Set<OnboardingStep> {
            let words = (try? container.decodeIfPresent([String].self, forKey: key)).flatMap { $0 } ?? []
            // Only screens that still exist under the same name keep a check.
            return Set(words.compactMap(OnboardingStep.init(rawValue:)))
        }
        let current = finishedAt != nil ? .done : (step(.current) ?? .permissions)
        let furthest = max(step(.furthest) ?? current, current)
        self.init(current: current, furthest: furthest, completed: steps(.completed), skipped: steps(.skipped),
                  startedAt: startedAt, finishedAt: finishedAt, dismissedAt: dismissedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(current, forKey: .current)
        try container.encode(furthest, forKey: .furthest)
        try container.encode(completed.map(\.rawValue).sorted(), forKey: .completed)
        try container.encode(skipped.map(\.rawValue).sorted(), forKey: .skipped)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(dismissedAt, forKey: .dismissedAt)
    }
}

/// The setup state machine: which screen is showing and which are satisfied.
/// The view owns no step logic of its own.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var progress: OnboardingProgress

    public init(progress: OnboardingProgress = OnboardingProgress()) {
        self.progress = progress
    }

    public var current: OnboardingStep { progress.current }

    /// Checks that setup can prove on its own; the rest come from the system.
    public static let testedSteps: Set<OnboardingStep> = [.microphone, .practice]

    public func isSatisfied(_ step: OnboardingStep, _ conditions: OnboardingConditions) -> Bool {
        switch step {
        case .permissions: return conditions.permissionsReady
        // A heard voice is meaningless once access is revoked.
        case .microphone: return conditions.microphoneGranted && progress.completed.contains(.microphone)
        case .practice: return progress.completed.contains(.practice)
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

    /// Starts (or resumes) a setup run.
    public mutating func begin(now: Date = Date()) {
        if progress.isInProgress {
            progress.dismissedAt = nil
            return
        }
        progress = OnboardingProgress(startedAt: now)
    }

    /// Records that a screen’s own check passed (a voice was heard, a
    /// practice dictation landed). Idempotent.
    public mutating func markPassed(_ step: OnboardingStep) {
        guard progress.completed.insert(step).inserted else { return }
        progress.skipped.remove(step)
    }

    /// A passed check no longer holds (e.g. the microphone changed).
    public mutating func invalidate(_ step: OnboardingStep) {
        progress.completed.remove(step)
    }

    /// Continue, or Skip on an unsatisfied screen. Tested screens are recorded
    /// as completed the moment their check passes; an untested screen counts as
    /// completed when the user moves past it satisfied.
    public mutating func advance(_ conditions: OnboardingConditions, now: Date = Date()) {
        guard canContinue(conditions) else { return }
        let step = current
        if step == .done { return finish(now: now) }
        if isSatisfied(step, conditions) {
            if !Self.testedSteps.contains(step), progress.completed.insert(step).inserted {
                progress.skipped.remove(step)
            }
        } else {
            progress.skipped.insert(step)
        }
        guard let next = step.next else { return }
        move(to: next)
    }

    public mutating func back() {
        guard let previous = current.previous else { return }
        progress.current = previous
    }

    public mutating func jump(to step: OnboardingStep) {
        guard canJump(to: step), step != current else { return }
        progress.current = step
    }

    public mutating func finish(now: Date = Date()) {
        guard !progress.isFinished else { return }
        progress.current = .done
        progress.furthest = .done
        progress.finishedAt = now
    }

    /// "Set up later": progress is kept so setup can resume where it stopped.
    public mutating func dismiss(now: Date = Date()) {
        guard !progress.isFinished else { return }
        progress.dismissedAt = now
    }

    /// "Run setup again" starts over from the first screen, keeping nothing.
    public mutating func restart(now: Date = Date()) {
        progress = OnboardingProgress(startedAt: now)
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
