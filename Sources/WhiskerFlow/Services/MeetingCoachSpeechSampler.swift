import Foundation
import WhiskerFlowCore

/// Feeds the private coach your own words while a meeting records: every 20
/// seconds of microphone audio in which you (not the other side of the call)
/// did most of the talking is transcribed on this Mac, and only the text is
/// kept, in memory, for pace and the experimental suggestions. Audio here is
/// never written anywhere; the meeting's own recording is unaffected.
@MainActor
final class MeetingCoachSpeechSampler {
    typealias Transcriber = @Sendable ([Float]) async -> String?

    private static let sampleRate = 16_000.0
    private let windowSamples = Int(MeetingLiveTranscriptionPolicy.windowSeconds * sampleRate)
    private var buffer: [Float] = []
    private var inFlight = false
    private let transcribe: Transcriber
    private weak var assistant: MeetingAssistantController?

    init(assistant: MeetingAssistantController, transcribe: @escaping Transcriber) {
        self.assistant = assistant
        self.transcribe = transcribe
    }

    func append(_ samples: [Float]) {
        guard let assistant, assistant.wantsOwnSpeech else {
            if !buffer.isEmpty { buffer.removeAll(keepingCapacity: false) }
            return
        }
        buffer.append(contentsOf: samples)
        guard buffer.count >= windowSamples else { return }
        let window = buffer
        buffer.removeAll(keepingCapacity: true)
        let end = assistant.elapsedSeconds
        let start = max(0, end - Double(window.count) / Self.sampleRate)
        // One transcription at a time; a busy model simply skips this window.
        guard !inFlight, assistant.shouldTranscribeOwnSpeech(from: start, to: end) else { return }
        inFlight = true
        let transcribe = transcribe
        Task { @MainActor [weak self] in
            let text = await transcribe(window)
            guard let self else { return }
            self.inFlight = false
            if let text, !text.isEmpty { self.assistant?.recordOwnSpeech(text, from: start, to: end) }
        }
    }

    func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
