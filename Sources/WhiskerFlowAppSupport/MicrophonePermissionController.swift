import Foundation
import Observation

public enum MicrophoneAuthorizationState: String, Equatable, Sendable {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case authorized
}

public enum MicrophonePermissionRecoveryAction: Equatable, Sendable {
    case request
    case openSettings
}

@MainActor
public protocol MicrophoneAuthorizationProviding {
    var authorizationState: MicrophoneAuthorizationState { get }
    func requestAccess() async
}

@MainActor
@Observable
public final class MicrophonePermissionController {
    public private(set) var authorizationState: MicrophoneAuthorizationState

    private let provider: any MicrophoneAuthorizationProviding

    public init(provider: any MicrophoneAuthorizationProviding) {
        self.provider = provider
        self.authorizationState = provider.authorizationState
    }

    public var isGranted: Bool {
        authorizationState == .authorized
    }

    public var recoveryAction: MicrophonePermissionRecoveryAction? {
        switch authorizationState {
        case .notDetermined:
            return .request
        case .restricted, .denied:
            return .openSettings
        case .authorized:
            return nil
        }
    }

    public var detail: String {
        switch authorizationState {
        case .notDetermined:
            return "Needed to record your voice."
        case .restricted:
            return "Microphone access is restricted by macOS."
        case .denied:
            return "Microphone access is off. Enable WhiskerFlow in System Settings."
        case .authorized:
            return "Ready to record."
        }
    }

    public var captureFailureMessage: String? {
        switch authorizationState {
        case .notDetermined:
            return "Microphone permission was not granted"
        case .restricted:
            return "Microphone access is restricted by macOS"
        case .denied:
            return "Microphone access is off — open Microphone Settings"
        case .authorized:
            return nil
        }
    }

    @discardableResult
    public func refresh() -> MicrophoneAuthorizationState {
        authorizationState = provider.authorizationState
        return authorizationState
    }

    public func refreshForApplicationActivation() {
        refresh()
    }

    @discardableResult
    public func requestIfNeeded() async -> MicrophoneAuthorizationState {
        refresh()
        guard authorizationState == .notDetermined else {
            return authorizationState
        }
        await provider.requestAccess()
        return refresh()
    }
}

public enum CaptureErrorPresentation {
    public static func message(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not start recording" : message
    }
}
