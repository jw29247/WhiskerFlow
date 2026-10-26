import Foundation

/// What macOS's Now Playing service says, read through the bundled helper
/// (see `NowPlayingBridge`).
public struct NowPlayingStatus: Equatable, Sendable {
    public var isPlaying: Bool
    /// The now-playing app's process, 0 when there is none.
    public var pid: Int32

    public init(isPlaying: Bool, pid: Int32) {
        self.isPlaying = isPlaying
        self.pid = pid
    }

    /// The helper prints `playing=<0|1>` and `pid=<n>` lines. Anything else
    /// is unknown, never "not playing".
    public static func parse(_ output: String) -> NowPlayingStatus? {
        let values = keyValues(output)
        guard let playing = values["playing"].flatMap(Int.init) else { return nil }
        return NowPlayingStatus(isPlaying: playing != 0, pid: values["pid"].flatMap(Int32.init) ?? 0)
    }

    /// Whether the helper saw a pause or play command take effect
    /// (`confirmed=1`). Older helpers only print `sent=`.
    public static func parseConfirmation(_ output: String) -> Bool {
        keyValues(output)["confirmed"] == "1"
    }

    private static func keyValues(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }
}

/// When dictation pauses media: only when macOS reports something actually
/// playing. Paused media, an unknown state, a call, or WhiskerFlow itself
/// leave everything as it is, so dictation never starts music.
public enum MediaPausePolicy {
    public enum Decision: String, Sendable {
        case pause
        case notPlaying = "not_playing"
        case unknown
        case call
        /// The playing app is itself on the microphone.
        case playingAppOnMicrophone = "playing_app_on_microphone"
        case ownApp = "own_app"
    }

    /// - Parameters:
    ///   - inCall: a call or meeting WhiskerFlow recognises is going on.
    ///   - nowPlayingBundleID: the now-playing app's bundle identifier, when known.
    ///   - inputs: the other processes using the microphone.
    public static func decide(
        _ status: NowPlayingStatus?,
        ownPID: Int32,
        inCall: Bool,
        nowPlayingBundleID: String? = nil,
        inputs: [AudioInputProcess] = []
    ) -> Decision {
        if inCall { return .call }
        guard let status else { return .unknown }
        guard status.isPlaying else { return .notPlaying }
        if status.pid == ownPID { return .ownApp }
        if isCapturing(nowPlayingPID: status.pid, bundleID: nowPlayingBundleID, inputs: inputs) {
            return .playingAppOnMicrophone
        }
        return .pause
    }

    /// The app that is playing is also using the microphone: a call (FaceTime,
    /// a web call the detector doesn't recognise), whose audio a pause would
    /// cut. Any other app on the microphone, such as a webcam utility or a
    /// noise filter, says nothing about the music, so it doesn't stop a pause.
    static func isCapturing(nowPlayingPID pid: Int32, bundleID: String?, inputs: [AudioInputProcess]) -> Bool {
        let marker = CallDetectionRules.webKitProcessMarker
        return inputs.contains { input in
            if input.pid == pid { return true }
            guard let bundleID, let inputBundle = input.bundleID else { return false }
            // Helpers extend the app's identifier (com.google.Chrome.helper).
            if inputBundle == bundleID || inputBundle.hasPrefix(bundleID + ".") { return true }
            // WebKit browsers capture in shared com.apple.WebKit.* processes.
            let webKitApp = bundleID.hasPrefix(marker) || CallDetectionRules.webKitBrowsers.contains(bundleID)
            return webKitApp && inputBundle.hasPrefix(marker)
        }
    }

    public enum ResumeDecision: String, Sendable {
        case play = "resumed"
        case alreadyPlaying = "already_playing"
        case appChanged = "app_changed"
    }

    /// Plays again only the app that dictation paused, and only while it is
    /// still paused. If macOS can't be asked, it plays: the pause was ours.
    public static func resumeDecision(_ status: NowPlayingStatus?, pausedPID: Int32) -> ResumeDecision {
        guard let status else { return .play }
        guard status.pid == pausedPID else { return .appChanged }
        return status.isPlaying ? .alreadyPlaying : .play
    }
}

/// Pairs each pause with exactly one resume, of the app that was paused.
public struct MediaPauseSession: Sendable {
    public private(set) var pausedPID: Int32?

    public init() {}

    public var isPaused: Bool { pausedPID != nil }

    public mutating func didPause(pid: Int32) { pausedPID = pid }

    /// The paused app's process, once after a pause.
    public mutating func takeResume() -> Int32? {
        defer { pausedPID = nil }
        return pausedPID
    }
}
