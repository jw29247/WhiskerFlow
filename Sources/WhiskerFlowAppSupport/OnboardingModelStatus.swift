import Foundation

/// Why the speech model could not be made ready, as far as setup can tell.
public enum OnboardingModelFailure: Equatable, Sendable {
    case offline
    case notEnoughSpace(neededBytes: Int64, availableBytes: Int64)
    case other

    /// Works out the likely cause after a failed preparation. Only a model
    /// that still had to download can fail for want of a network or space.
    public static func classify(
        neededDownload: Bool,
        isOnline: Bool,
        availableBytes: Int64?,
        downloadBytes: Int64
    ) -> OnboardingModelFailure {
        guard neededDownload else { return .other }
        if !isOnline { return .offline }
        if let availableBytes, availableBytes < downloadBytes {
            return .notEnoughSpace(neededBytes: downloadBytes, availableBytes: availableBytes)
        }
        return .other
    }
}

/// The speech model as setup shows it.
public enum OnboardingModelPhase: Equatable, Sendable {
    case notStarted
    case downloading(fraction: Double)
    case loading
    case optimising
    case ready
    case failed(OnboardingModelFailure)

    public var isPreparing: Bool {
        switch self {
        case .downloading, .loading, .optimising: return true
        default: return false
        }
    }
}

/// What can start a model preparation from setup.
public enum OnboardingModelTrigger: Equatable, Sendable {
    /// Setup opened. The app normally started the download at launch already.
    case setupOpened
    /// The person chose Retry.
    case retry
    /// The Mac came back online.
    case cameOnline
}

/// Whether setup should start a preparation. A running or finished one is
/// never started again: preparing twice would cancel the first download and
/// begin a second.
public enum OnboardingModelPolicy {
    public static func shouldStart(_ phase: OnboardingModelPhase, trigger: OnboardingModelTrigger) -> Bool {
        switch (phase, trigger) {
        case (.downloading, _), (.loading, _), (.optimising, _), (.ready, _): return false
        case (.notStarted, _): return true
        // Reconnecting only helps a download that failed for want of a network.
        case (.failed(let failure), .cameOnline): return failure == .offline
        case (.failed, .setupOpened), (.failed, .retry): return true
        }
    }
}

/// What the practice screen shows about the speech model, and whether the
/// person can practise yet.
public struct OnboardingPracticeReadiness: Equatable, Sendable {
    public let phase: OnboardingModelPhase
    /// Dictation falls back to Apple's recogniser when the model fails.
    public let fallbackAllowed: Bool

    public init(phase: OnboardingModelPhase, fallbackAllowed: Bool) {
        self.phase = phase
        self.fallbackAllowed = fallbackAllowed
    }

    /// Practice opens by itself the moment this turns true.
    public var canPractise: Bool {
        switch phase {
        case .ready: return true
        case .failed: return fallbackAllowed
        default: return false
        }
    }

    public var showsProgress: Bool { phase == .notStarted || phase.isPreparing }

    /// Nil while indeterminate.
    public var progressFraction: Double? {
        if case .downloading(let fraction) = phase { return min(max(fraction, 0), 1) }
        return nil
    }

    public var offersRetry: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// One line for the model's state, or nil once it is ready.
    public var headline: String? {
        switch phase {
        case .ready: return nil
        case .notStarted: return "Getting the speech model ready…"
        case .downloading: return "Downloading the speech model…"
        case .loading: return "Loading the speech model…"
        case .optimising: return "Setting up the speech model for this Mac…"
        case .failed(.offline): return "You’re offline, so the speech model can’t download."
        case .failed(.notEnoughSpace): return "There isn’t enough free space for the speech model."
        case .failed(.other): return "The speech model didn’t load."
        }
    }

    /// What happens next, or what to do.
    public var detail: String? {
        switch phase {
        case .ready: return nil
        case .notStarted, .downloading, .loading, .optimising:
            return "This only happens once. Practice starts by itself when it’s ready."
        case .failed(let failure):
            let action: String
            switch failure {
            case .offline:
                action = "Connect to the internet. It tries again by itself, or choose Retry."
            case .notEnoughSpace(let needed, let available):
                action = "It needs \(Self.bytes(needed)) and this Mac has \(Self.bytes(available)) free. Free up some space, then choose Retry."
            case .other:
                action = "Choose Retry. If it fails again, quit and reopen WhiskerFlow."
            }
            return fallbackAllowed ? action + " Until then, you can practise with Apple’s speech recognition." : action
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
