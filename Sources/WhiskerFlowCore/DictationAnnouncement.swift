import Foundation

/// Speaks a short message to assistive technology (VoiceOver).
@MainActor
public protocol DictationAnnouncing: AnyObject {
    /// Whether anything is listening. When false nothing is announced, so a
    /// Mac without VoiceOver pays nothing beyond this check.
    var isActive: Bool { get }
    func announce(_ message: String)
}

public enum DictationAnnouncement {
    public static let transcribing = "Transcribing"

    /// What to say when the HUD moves from `old` to `new`, or nil for nothing.
    /// Outcome messages are the HUD's own text, so the two never disagree. A
    /// message ending in "…" ("Pasting…") is a step on the way to an outcome
    /// that is announced a moment later, so it is not spoken. Live transcript
    /// text is never part of a presentation, so it is never announced.
    ///
    /// Nothing is spoken when recording starts: the microphone is live, so
    /// VoiceOver's voice from the speakers would be recorded into the
    /// dictation and talk over its first words. The start sound is the cue.
    public static func message(from old: FloatingHUDPresentation, to new: FloatingHUDPresentation) -> String? {
        guard old != new else { return nil }
        switch new {
        case .hidden, .recording: return nil
        case .transcribing: return transcribing
        case .notification(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasSuffix("…") else { return nil }
            return trimmed
        case .failure(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Dictation failed" : "Dictation failed: \(trimmed)"
        }
    }
}

/// Remembers the last HUD presentation and announces each change once.
/// Fed by the HUD controller after the state has already changed, never from
/// the recording or paste code.
@MainActor
public final class DictationAnnouncementTracker {
    private let announcer: DictationAnnouncing
    private var last: FloatingHUDPresentation = .hidden

    public init(announcer: DictationAnnouncing) {
        self.announcer = announcer
    }

    public func observe(_ presentation: FloatingHUDPresentation) {
        let previous = last
        last = presentation
        guard announcer.isActive,
              let message = DictationAnnouncement.message(from: previous, to: presentation) else { return }
        announcer.announce(message)
    }
}
