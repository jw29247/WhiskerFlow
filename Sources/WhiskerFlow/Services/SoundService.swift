import AppKit

@MainActor
struct SoundService {
    enum Cue: Sendable {
        case recordingStarted
        case recordingStopped
        case transcriptionSucceeded
        case transcriptionFailed
    }

    private static let playbackQueue = DispatchQueue(label: "WhiskerFlow.sound", qos: .utility)
    private let playback: @Sendable (Cue) -> Void

    init(playback: @escaping @Sendable (Cue) -> Void = { cue in
        NSSound(named: Self.soundName(for: cue))?.play()
    }) {
        self.playback = playback
    }

    func play(_ cue: Cue) {
        let playback = self.playback
        let requestedAt = ProcessInfo.processInfo.systemUptime
        // Audio-device startup can block inside NSSound.play. Keep every sound
        // lookup/play on one worker queue, never on the dictation delivery path.
        Self.playbackQueue.async {
            guard ProcessInfo.processInfo.systemUptime - requestedAt < 1 else { return }
            autoreleasepool { playback(cue) }
        }
    }

    nonisolated private static func soundName(for cue: Cue) -> NSSound.Name {
        switch cue {
        case .recordingStarted:
            .init("Tink")
        case .recordingStopped:
            .init("Pop")
        case .transcriptionSucceeded:
            .init("Glass")
        case .transcriptionFailed:
            .init("Basso")
        }
    }
}
