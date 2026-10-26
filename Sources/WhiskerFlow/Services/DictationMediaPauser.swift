import AppKit
import Foundation
import Logging
import WhiskerFlowAppSupport

private let mediaPauseLogger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

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
    /// The play command, until the app confirms or the helper gives up.
    private var playing: Task<Void, Never>?
    private var generation = 0
    private let ownPID: Int32
    private let ownBundleID: String?
    private let readStatus: @Sendable () -> NowPlayingStatus?
    private let readProcesses: @Sendable () -> [CoreAudioProcesses.Process]
    private let bundleIDForPID: @Sendable (Int32) -> String?
    /// Returns whether the app reported the new state.
    private let send: @Sendable (Command) -> Bool

    init(
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        readStatus: @escaping @Sendable () -> NowPlayingStatus? = { NowPlayingBridge.status() },
        readProcesses: @escaping @Sendable () -> [CoreAudioProcesses.Process] = { CoreAudioProcesses.current() },
        bundleIDForPID: @escaping @Sendable (Int32) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        },
        send: @escaping @Sendable (Command) -> Bool = { command in
            switch command {
            case .pause: return NowPlayingBridge.pause()
            case .play: return NowPlayingBridge.play()
            }
        }
    ) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        self.readStatus = readStatus
        self.readProcesses = readProcesses
        self.bundleIDForPID = bundleIDForPID
        self.send = send
    }

    /// Called at key press. The check runs off the main thread and never
    /// holds up the microphone.
    /// - Parameter inCall: a call or meeting WhiskerFlow recognises is going on.
    func dictationStarted(inCall: Bool) {
        generation &+= 1
        if let resume {
            // Still paused from the dictation that just ended.
            resume.cancel()
            self.resume = nil
            if session.isPaused { return }
        }
        guard !inCall else {
            Self.log("media_pause_checked", decision: MediaPausePolicy.Decision.call.rawValue)
            return
        }
        let id = generation
        let (ownPID, ownBundleID) = (ownPID, ownBundleID)
        let (readStatus, readProcesses, bundleIDForPID) = (readStatus, readProcesses, bundleIDForPID)
        let resuming = playing
        check = Task { @MainActor [weak self] in
            // Media still resuming from the last dictation would read as paused.
            await resuming?.value
            let started = Date()
            let (decision, pid) = await Task.detached(priority: .userInitiated) { () -> (MediaPausePolicy.Decision, Int32) in
                let status = readStatus()
                // WhiskerFlow's own capture, and its helpers, aren't the playing app.
                let inputs = readProcesses()
                    .filter { $0.isRunningInput && $0.pid != ownPID }
                    .filter { process in
                        guard let own = ownBundleID, let bundleID = process.bundleID else { return true }
                        return bundleID != own && !bundleID.hasPrefix(own + ".")
                    }
                    .map { AudioInputProcess(pid: $0.pid, bundleID: $0.bundleID) }
                let playingBundleID = status.flatMap { $0.pid > 0 ? bundleIDForPID($0.pid) : nil }
                let decision = MediaPausePolicy.decide(status, ownPID: ownPID, inCall: false,
                                                       nowPlayingBundleID: playingBundleID, inputs: inputs)
                return (decision, status?.pid ?? 0)
            }.value
            let elapsed = Date().timeIntervalSince(started)
            // A quick tap can end before the check returns: leave media alone.
            guard let self, self.generation == id, !Task.isCancelled else {
                Self.log("media_pause_checked", decision: "superseded", elapsed: elapsed)
                return
            }
            Self.log("media_pause_checked", decision: decision.rawValue, elapsed: elapsed)
            guard decision == .pause else { return }
            self.session.didPause(pid: pid)
            let send = self.send
            Task.detached(priority: .userInitiated) {
                let confirmed = send(.pause)
                Self.log("media_paused", confirmed: confirmed)
            }
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
        let (send, readStatus) = (send, readStatus)
        resume = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.resumeDelayNanoseconds)
            guard let self, !Task.isCancelled, let pausedPID = self.session.pausedPID else { return }
            // Only the app dictation paused, and only if it is still paused.
            let decision = await Task.detached(priority: .userInitiated) {
                MediaPausePolicy.resumeDecision(readStatus(), pausedPID: pausedPID)
            }.value
            // A dictation that started during the check cancelled this resume
            // and keeps the media paused.
            guard !Task.isCancelled else { return }
            self.resume = nil
            _ = self.session.takeResume()
            guard decision == .play else {
                Self.log("media_resumed", decision: decision.rawValue)
                return
            }
            self.playing = Task.detached(priority: .userInitiated) {
                let confirmed = send(.play)
                Self.log("media_resumed", decision: decision.rawValue, confirmed: confirmed)
            }
        }
    }

    /// Allowlisted in `LocalDiagnosticLogHandler`; no app names are recorded.
    private nonisolated static func log(
        _ event: String, decision: String? = nil, elapsed: TimeInterval? = nil, confirmed: Bool? = nil
    ) {
        var metadata: Logging.Logger.Metadata = ["event": .string(event)]
        if let decision { metadata["media_decision"] = .string(decision) }
        if let elapsed { metadata["elapsed_ms"] = .string(String(Int(elapsed * 1000))) }
        if let confirmed { metadata["confirmed"] = .string(String(confirmed)) }
        mediaPauseLogger.info("Media pause", metadata: metadata)
    }
}
