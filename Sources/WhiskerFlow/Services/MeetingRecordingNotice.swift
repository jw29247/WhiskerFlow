import Foundation
import Observation

/// The sentence the user pastes into the meeting chat to tell the other
/// participants they are being recorded. WhiskerFlow cannot post it itself.
enum MeetingRecordingNotice {
    static let defaultText =
        "I’m recording and transcribing this meeting with WhiskerFlow. The recording is stored in our Atlas workspace. Tell me if you’d rather I didn’t record."

    /// The user's own wording, or the default when it is empty or blank.
    static func text(custom: String) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultText : trimmed
    }
}

/// "Tell the others you're recording": raised for every meeting recording,
/// however it started, and kept until the user dismisses it or copies the
/// notice. It never touches the clipboard by itself and sends nothing.
@MainActor
@Observable
final class MeetingRecordingReminder {
    enum State: Equatable {
        case hidden
        case showing(sessionID: UUID)
        /// The notice was copied; a short confirmation shows before it hides.
        case copied(sessionID: UUID)
    }

    private(set) var state: State = .hidden
    @ObservationIgnored private let wait: @MainActor () async -> Void
    @ObservationIgnored private(set) var confirmationTask: Task<Void, Never>?

    init(wait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(3)) }) {
        self.wait = wait
    }

    /// The recording the reminder belongs to, while it is visible.
    var sessionID: UUID? {
        switch state {
        case .hidden: return nil
        case .showing(let id), .copied(let id): return id
        }
    }

    var isCopied: Bool { if case .copied = state { return true } else { return false } }

    /// Visible only for the recording in progress, so a stopped recording
    /// takes its reminder with it.
    func isVisible(during activeSessionID: UUID?) -> Bool {
        activeSessionID != nil && sessionID == activeSessionID
    }

    /// Called once a recording has actually started. Every recording is
    /// reminded about, whatever happened to the previous one's reminder.
    func recordingStarted(sessionID: UUID) {
        confirmationTask?.cancel()
        confirmationTask = nil
        state = .showing(sessionID: sessionID)
    }

    func dismiss() {
        confirmationTask?.cancel()
        confirmationTask = nil
        state = .hidden
    }

    /// Copies `text` through the app's copy path, confirms, then hides.
    func copy(_ text: String, using copy: (String) -> Void) {
        guard case .showing(let id) = state else { return }
        copy(text)
        state = .copied(sessionID: id)
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor [weak self, wait] in
            await wait()
            guard !Task.isCancelled, let self, self.state == .copied(sessionID: id) else { return }
            self.state = .hidden
        }
    }

    #if DEBUG
    /// The confirmation after Copy, held for a preview snapshot.
    func showCopiedForPreview() {
        guard case .showing(let id) = state else { return }
        state = .copied(sessionID: id)
    }
    #endif
}
