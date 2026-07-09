import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Live, low-latency dictation using the app-owned AVAudioEngine capture service.
///
/// While the key is held, audio streams into a 16 kHz float buffer and a decode
/// loop continuously re-transcribes the growing buffer off the warm pipe, so the
/// latest transcript is ready the instant the key is released. On `finish()` we
/// return that latest partial (plus the raw samples, for history / retry).
@MainActor
final class LiveDictationSession {
    private let transcription: TranscriptionService
    private let audioCapture = AudioCaptureService()

    /// Called on the main actor whenever a fresher partial transcript is ready.
    var onPartial: ((String) -> Void)?
    /// Called on the main actor with a normalized 0...1 input level.
    var onLevel: ((Float) -> Void)?
    /// Called after AVFoundation reports that the active input configuration changed.
    var onConfigurationChange: (() -> Void)?

    private var decodeLoop: Task<Void, Never>?
    private var language: String?
    private var model: WhisperModel = .tiny
    private var vocabulary = Vocabulary()
    private var latestText = ""
    private var lastDecodedSampleCount = 0
    private var isRunning = false
    private var isStreaming = false

    private static let sampleRate = 16_000.0
    /// Re-decode once this much new audio has accumulated since the last pass.
    private static let minNewSamples = Int(sampleRate * 0.4)
    /// On release, if more than this much audio went undecoded (only happens when
    /// decoding fell behind real time on a long hold), do one final clean pass.
    private static let staleSampleThreshold = Int(sampleRate * 1.5)

    init(transcription: TranscriptionService) {
        self.transcription = transcription
        audioCapture.onLevel = { [weak self] level in self?.onLevel?(level) }
        audioCapture.onConfigurationChange = { [weak self] in self?.onConfigurationChange?() }
    }

    /// Begin capturing and (if `streaming`) live-decoding. Throws if the mic
    /// engine can't start. Requires microphone permission to already be granted.
    func start(
        selection: AudioInputSelection,
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
        isStreaming = streaming
        do {
            try audioCapture.start(selection: selection)
            isRunning = true
        } catch {
            isRunning = false
            isStreaming = false
            throw error
        }

        if streaming {
            startDecodeLoop()
        }
    }

    /// Stop capture and return the freshest transcript plus the captured samples.
    func finish(reason: CaptureStopReason = .userReleased) async -> (text: String, samples: [Float]) {
        isRunning = false
        let loop = decodeLoop
        decodeLoop = nil
        let captured = audioCapture.stop(reason: reason)
        await loop?.value
        let samples = captured.samples

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
        audioCapture.cancel()
        latestText = ""
        lastDecodedSampleCount = 0
        onLevel?(0)
    }

    // MARK: - Decode loop

    private func startDecodeLoop() {
        decodeLoop = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                let samples = self.audioCapture.snapshot()
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

}
