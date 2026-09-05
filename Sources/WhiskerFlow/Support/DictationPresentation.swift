import SwiftUI
import WhiskerFlowCore

/// All shortcut and delivery copy derives from the user's actual configuration.
@MainActor
struct DictationPresentation {
    let appState: AppState

    var needsSetup: Bool {
        !appState.hasMicrophonePermission || !appState.hasAccessibilityPermission
    }

    var heading: String {
        if appState.isRecording { return "Listening to you." }
        if appState.isTranscribing { return "Putting it into words." }
        if case .preparingMic = appState.status { return "Opening your microphone." }
        if needsSetup { return "Make room for your voice." }
        if case .failure = appState.status { return "Let’s get you back on track." }
        switch appState.modelState {
        case .ready: return "Ready when you are."
        case .preparing, .unloaded: return "Getting ready for you."
        case .failed: return "Your voice needs a moment."
        }
    }

    var statusTitle: String {
        if appState.isRecording { return "Recording" }
        if appState.isTranscribing { return "Transcribing" }
        if needsSetup { return "Setup needed" }
        if case .failure = appState.status { return "Needs attention" }
        if case .preparingMic = appState.status { return "Preparing microphone" }
        switch appState.modelState {
        case .ready: return "Ready"
        case .preparing, .unloaded: return "Preparing"
        case .failed: return "Needs attention"
        }
    }

    var statusColor: Color {
        if appState.isRecording { return FlowStyle.recording }
        if needsSetup || failure != nil { return .orange }
        return appState.modelState == .ready ? .green : FlowStyle.accent
    }

    var gesture: String { appState.settings.recordingMode == .holdToTalk ? "Hold" : "Press" }
    var finish: String { appState.settings.recordingMode == .holdToTalk ? "Release" : "Press again" }
    var deliveryDescription: String {
        let destination = appState.settings.delivery == .pasteAtCursor ? "at your cursor" : "on your clipboard"
        return "\(finish) to turn your words into text \(destination)."
    }
    var failure: String? {
        if case .failure(let message) = appState.status { return message }
        if case .failed(let message) = appState.modelState { return message }
        return nil
    }
}
