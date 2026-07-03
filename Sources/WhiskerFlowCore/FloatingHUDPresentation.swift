import Foundation

public enum FloatingHUDPresentation: Equatable, Sendable {
    case hidden
    case recording
    case transcribing
    case notification(String)

    public static func current(
        isRecording: Bool,
        isTranscribing: Bool,
        successMessage: String?
    ) -> FloatingHUDPresentation {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        if let successMessage, !successMessage.isEmpty {
            return .notification(successMessage)
        }
        return .hidden
    }

    public var isVisible: Bool {
        self != .hidden
    }

    public var hidesAutomatically: Bool {
        if case .notification = self { return true }
        return false
    }
}
