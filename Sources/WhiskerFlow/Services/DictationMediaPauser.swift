import AppKit
import WhiskerFlowAppSupport

/// Pauses whatever is playing while the user dictates, with the system
/// play/pause key, and presses it again when dictation stops. See
/// `MediaPausePolicy` for when it presses at all.
@MainActor
final class DictationMediaPauser {
    /// Back-to-back dictations keep the media paused instead of letting it
    /// blip on between them.
    static let resumeDelayNanoseconds: UInt64 = 400_000_000

    private var session = MediaPauseSession()
    private var check: Task<Void, Never>?
    private var resume: Task<Void, Never>?
    private var generation = 0
    private let ownBundleID: String?
    private let readProcesses: @Sendable () -> [CoreAudioProcesses.Process]
    private let postPlayPause: () -> Void

    init(
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        readProcesses: @escaping @Sendable () -> [CoreAudioProcesses.Process] = { CoreAudioProcesses.current() },
        postPlayPause: @escaping () -> Void = { MediaKey.postPlayPause() }
    ) {
        self.ownBundleID = ownBundleID
        self.readProcesses = readProcesses
        self.postPlayPause = postPlayPause
    }

    /// Called at key press. The check runs off the main thread and never
    /// holds up the microphone.
    func dictationStarted(inCall: Bool) {
        generation &+= 1
        if let resume {
            // Still paused from the dictation that just ended.
            resume.cancel()
            self.resume = nil
            if session.isPaused { return }
        }
        guard !inCall else { return }
        let id = generation
        let own = ownBundleID
        let read = readProcesses
        check = Task { @MainActor [weak self] in
            let processes = await Task.detached(priority: .userInitiated) { read() }.value
            guard let self, self.generation == id, !Task.isCancelled else { return }
            let otherAppUsingMicrophone = processes.contains { $0.isRunningInput && $0.bundleID != own }
            guard MediaPausePolicy.shouldPause(
                processesPlayingAudio: processes.filter(\.isRunningOutput).map(\.bundleID),
                ownBundleID: own, inCall: otherAppUsingMicrophone
            ) else { return }
            self.postPlayPause()
            self.session.didPause()
        }
    }

    /// Called when capture stops, whether it finished, failed or was cancelled.
    func dictationEnded() {
        generation &+= 1
        check?.cancel()
        check = nil
        guard session.isPaused, resume == nil else { return }
        resume = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.resumeDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.resume = nil
            if self.session.shouldResume() { self.postPlayPause() }
        }
    }
}

/// The keyboard's play/pause key, as macOS delivers it to the "now playing" app.
enum MediaKey {
    /// `NX_KEYTYPE_PLAY` in IOKit's `ev_keymap.h`.
    private static let playPause = 16

    static func postPlayPause() {
        for keyDown in [true, false] {
            let state = keyDown ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (playPause << 16) | (state << 8), data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
