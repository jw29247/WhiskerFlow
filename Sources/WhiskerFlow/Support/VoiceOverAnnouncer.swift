import AppKit
import WhiskerFlowCore

/// Posts dictation announcements to VoiceOver. Whether VoiceOver is running
/// is cached from key-value observation, so the check per HUD change is a
/// stored Bool read.
@MainActor
final class VoiceOverAnnouncer: DictationAnnouncing {
    private(set) var isActive = NSWorkspace.shared.isVoiceOverEnabled
    private var observation: NSKeyValueObservation?

    init() {
        observation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in self?.isActive = enabled }
        }
    }

    func announce(_ message: String) {
        // Posted on a later main-actor turn, so the HUD update that triggered
        // it finishes first and nothing waits on VoiceOver.
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
}
