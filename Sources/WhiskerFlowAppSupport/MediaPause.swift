import Foundation

/// When dictation pauses media. The play/pause key goes to macOS's "now
/// playing" app, so it is pressed only when a media app or a browser is
/// actually putting out sound: with nothing playing, the same key would start
/// the last player instead.
public enum MediaPausePolicy {
    /// Players whose audio is media. Browsers count too (video and music
    /// sites take the media key).
    public static let mediaApps: Set<String> = [
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX", "com.apple.iBooksX",
        "com.spotify.client", "com.tidal.desktop", "com.deezer.deezer-desktop", "com.amazon.music",
        "org.videolan.vlc", "com.colliderli.iina", "tv.plex.desktop", "tv.plex.plexamp",
        "com.github.th-ch.youtube-music", "au.com.shiftyjelly.PocketCasts", "fm.overcast.overcast",
    ]

    /// - Parameters:
    ///   - processesPlayingAudio: bundle IDs of processes whose audio output is
    ///     running (helpers included, such as `com.google.Chrome.helper`).
    ///   - inCall: a call or meeting is going on, or another app is using the
    ///     microphone (a call the detector didn't recognise).
    public static func shouldPause(processesPlayingAudio: [String?], ownBundleID: String?, inCall: Bool) -> Bool {
        guard !inCall else { return false }
        return processesPlayingAudio.contains { bundleID in
            guard let bundleID, bundleID != ownBundleID else { return false }
            if bundleID.hasPrefix("com.apple.WebKit") { return true }
            return (mediaApps.union(CallDetectionRules.browsers)).contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
        }
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
