import Foundation
import WhisperKit
import WhiskerFlowCore

/// Live, low-latency dictation built on WhisperKit's `AudioProcessor`.
///
/// While the key is held, audio streams into a 16 kHz float buffer and a decode
/// loop continuously re-transcribes the growing buffer off the warm pipe, so the
/// latest transcript is ready the instant the key is released. On `finish()` we
/// return that latest partial (plus the raw samples, for history / retry).
@MainActor
final class LiveDictationSession {
    private let transcription: TranscriptionService
    private let audioProcessor = AudioProcessor()

    /// Called on the main actor whenever a fresher partial transcript is ready.
    var onPartial: ((String) -> Void)?
    /// Called on the main actor with a normalized 0...1 input level.
    var onLevel: ((Float) -> Void)?

    private var decodeLoop: Task<Void, Never>?
    private var language: String?
    private var model: WhisperModel = .tiny
    private var vocabulary = Vocabulary()
    private var latestText = ""
    private var lastDecodedSampleCount = 0
    private var isRunning = false
    private var isStreaming = false

    private static let sampleRate = Double(WhisperKit.sampleRate) // 16 kHz
    /// Re-decode once this much new audio has accumulated since the last pass.
    private static let minNewSamples = Int(sampleRate * 0.4)
    /// On release, if more than this much audio went undecoded (only happens when
    /// decoding fell behind real time on a long hold), do one final clean pass.
    private static let staleSampleThreshold = Int(sampleRate * 1.5)

    init(transcription: TranscriptionService) {
        self.transcription = transcription
    }

    /// Begin capturing and (if `streaming`) live-decoding. Throws if the mic
    /// engine can't start. Requires microphone permission to already be granted.
    func start(
        deviceID: String,
        language: String?,
        model: WhisperModel,
        vocabulary: Vocabulary,
        streaming: Bool
    ) throws {
        self.language = language
        self.model = model
        self.vocabulary = vocabulary
        latestText = ""
        lastDecodedSampleCount = 0
        isRunning = true
        isStreaming = streaming

        try audioProcessor.startRecordingLive(inputDeviceID: Microphone.deviceID(from: deviceID)) { [weak self] buffer in
            let level = Self.level(from: buffer)
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }

        if streaming {
            startDecodeLoop()
        }
    }

    /// Stop capture and return the freshest transcript plus the captured samples.
    func finish() async -> (text: String, samples: [Float]) {
        isRunning = false
        audioProcessor.stopRecording()           // freeze the buffer
        await decodeLoop?.value                   // let any in-flight decode settle
        decodeLoop = nil

        let samples = Array(audioProcessor.audioSamples)

        // Fall back to a final decode only when we have no partial yet (utterance
        // shorter than the first decode) or decoding lagged badly on a long hold.
        if isStreaming {
            let undecoded = samples.count - lastDecodedSampleCount
            if (latestText.isEmpty || undecoded > Self.staleSampleThreshold), !samples.isEmpty {
                await decode(samples)
            }
        }

        let finalText = latestText
        latestText = ""
        lastDecodedSampleCount = 0
        onLevel?(0)
        return (finalText, samples)
    }

    /// Abort without producing a transcript (e.g. permission revoked mid-flight).
    func cancel() {
        isRunning = false
        decodeLoop?.cancel()
        decodeLoop = nil
        audioProcessor.stopRecording()
        latestText = ""
        lastDecodedSampleCount = 0
        onLevel?(0)
    }

    // MARK: - Decode loop

    private func startDecodeLoop() {
        decodeLoop = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                let samples = Array(self.audioProcessor.audioSamples)
                if samples.count - self.lastDecodedSampleCount >= Self.minNewSamples {
                    self.lastDecodedSampleCount = samples.count
                    await self.decode(samples)
                } else {
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
                }
            }
        }
    }

    private func decode(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        do {
            let result = try await transcription.transcribeSamples(samples, language: language, model: model)
            let text = vocabulary.apply(to: result.text)
            if !text.isEmpty {
                latestText = text
                onPartial?(text)
            }
        } catch {
            // Partial decode failures are non-fatal — keep the previous text.
        }
    }

    // MARK: - Level metering

    /// Normalized 0...1 level from a buffer of float samples, using the same
    /// dBFS mapping the old AVCapture meter used so the HUD looks unchanged.
    private static func level(from buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in buffer { sum += sample * sample }
        let rms = (sum / Float(buffer.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let floor: Float = -50
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / -floor
    }
}
