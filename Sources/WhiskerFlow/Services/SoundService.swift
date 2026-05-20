import AppKit

@MainActor
struct SoundService {
    enum Cue {
        case recordingStarted
        case recordingStopped
        case transcriptionSucceeded
        case transcriptionFailed
    }

    func play(_ cue: Cue) {
        NSSound(named: soundName(for: cue))?.play()
    }

    private func soundName(for cue: Cue) -> NSSound.Name {
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
