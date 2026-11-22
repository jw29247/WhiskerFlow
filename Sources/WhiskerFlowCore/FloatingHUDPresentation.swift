import Foundation

public enum FloatingHUDPresentation: Equatable, Sendable {
    case hidden
    case recording
    case transcribing
    case notification(String)
    /// A dictation that went wrong in a way the user needs to know about.
    case failure(String)

    /// How long a finished dictation's outcome stays on screen.
    public static let notificationDuration: TimeInterval = 1.1
    /// Long enough to read a short reason without looking for it.
    public static let failureDuration: TimeInterval = 4

    public static func current(
        isRecording: Bool,
        isTranscribing: Bool,
        successMessage: String?,
        failureMessage: String? = nil
    ) -> FloatingHUDPresentation {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        if let failureMessage, !failureMessage.isEmpty {
            return .failure(failureMessage)
        }
        if let successMessage, !successMessage.isEmpty {
            return .notification(successMessage)
        }
        return .hidden
    }

    public var isVisible: Bool {
        self != .hidden
    }

    public var hidesAutomatically: Bool {
        displayDuration != nil
    }

    /// Nil while the HUD follows live state (recording, transcribing).
    public var displayDuration: TimeInterval? {
        switch self {
        case .notification: return Self.notificationDuration
        case .failure: return Self.failureDuration
        case .hidden, .recording, .transcribing: return nil
        }
    }
}
