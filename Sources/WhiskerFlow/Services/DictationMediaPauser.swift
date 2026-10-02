import Foundation
import WhiskerFlowAppSupport

/// Pauses whatever is playing while the user dictates and plays it again when
/// dictation stops. It asks macOS what is playing first (`NowPlayingBridge`)
/// and sends an explicit pause, then an explicit play, so nothing that was
/// paused or silent is ever started. See `MediaPausePolicy`.
@MainActor
final class DictationMediaPauser {
    /// Back-to-back dictations keep the media paused instead of letting it
    /// blip on between them.
    static let resumeDelayNanoseconds: UInt64 = 400_000_000

    enum Command: Sendable { case pause, play }

    private var session = MediaPauseSession()
    private var check: Task<Void, Never>?
    private var resume: Task<Void, Never>?
    private var generation = 0
    private let ownPID: Int32
    private let ownBundleID: String?
    private let readStatus: @Sendable () -> NowPlayingStatus?
    private let readProcesses: @Sendable () -> [CoreAudioProcesses.Process]
    private let send: @Sendable (Command) -> Void

    init(
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        readStatus: @escaping @Sendable () -> NowPlayingStatus? = { NowPlayingBridge.status() },
        readProcesses: @escaping @Sendable () -> [CoreAudioProcesses.Process] = { CoreAudioProcesses.current() },
        send: @escaping @Sendable (Command) -> Void = { command in
            switch command {
            case .pause: NowPlayingBridge.pause()
            case .play: NowPlayingBridge.play()
            }
        }
    ) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        self.readStatus = readStatus
        self.readProcesses = readProcesses
        self.send = send
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
        let (own, ownPID) = (ownBundleID, ownPID)
        let (readStatus, readProcesses, send) = (readStatus, readProcesses, send)
        check = Task { @MainActor [weak self] in
            let shouldPause = await Task.detached(priority: .userInitiated) { () -> Bool in
                // A call the detector missed still holds the microphone.
                let otherAppUsingMicrophone = readProcesses().contains { $0.isRunningInput && $0.bundleID != own }
                return MediaPausePolicy.shouldPause(readStatus(), ownPID: ownPID, inCall: otherAppUsingMicrophone)
            }.value
            // A quick tap can end before the check returns: leave media alone.
            guard let self, shouldPause, self.generation == id, !Task.isCancelled else { return }
            self.session.didPause()
            Task.detached(priority: .userInitiated) { send(.pause) }
        }
    }

    /// Called when capture stops, whether it finished, failed or was cancelled.
    func dictationEnded() {
        generation &+= 1
        check?.cancel()
        check = nil
        scheduleResume()
    }

    private func scheduleResume() {
        guard session.isPaused, resume == nil else { return }
        let send = send
        resume = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.resumeDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.resume = nil
            if self.session.shouldResume() {
                Task.detached(priority: .userInitiated) { send(.play) }
            }
        }
    }
}
