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
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let playing = values["playing"].flatMap(Int.init) else { return nil }
        return NowPlayingStatus(isPlaying: playing != 0, pid: values["pid"].flatMap(Int32.init) ?? 0)
    }
}

/// When dictation pauses media: only when macOS reports something actually
/// playing. Paused media, an unknown state, a call, or WhiskerFlow itself
/// leave everything as it is, so dictation never starts music.
public enum MediaPausePolicy {
    /// - Parameter inCall: a call or meeting is going on, or another app is
    ///   using the microphone (a call the detector didn't recognise).
    public static func shouldPause(_ status: NowPlayingStatus?, ownPID: Int32, inCall: Bool) -> Bool {
        guard !inCall, let status, status.isPlaying else { return false }
        return status.pid != ownPID
    }
}

/// Pairs each pause with exactly one resume.
public struct MediaPauseSession: Sendable {
    private var paused = false

    public init() {}

    public var isPaused: Bool { paused }

    public mutating func didPause() { paused = true }

    /// True once after a pause.
    public mutating func shouldResume() -> Bool {
        defer { paused = false }
        return paused
    }
}
