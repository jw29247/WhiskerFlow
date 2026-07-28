import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Live, low-latency dictation using the app-owned AVAudioEngine capture service.
///
/// While the key is held, audio streams into a 16 kHz float buffer and a decode
/// loop continuously re-transcribes only the audio after the last confirmed cut,
/// so the cost per pass stays flat however long the hold runs. The text before a
/// cut is kept verbatim and the freshest transcript is the confirmed prefix plus
/// the current window, ready the instant the key is released. On `finish()` we
/// return that transcript (plus the raw samples, for history / retry).
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
    private var vocabulary = CompiledVocabulary(Vocabulary())
    private var formatting = FormattingOptions()
    private var confirmedText = ""
    private var confirmedSampleCount = 0
    private var windowText = ""
    /// Absolute position in the capture buffer that the transcript reaches.
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
        formatting: FormattingOptions,
        streaming: Bool
    ) throws {
        self.language = language
        self.model = model
        self.vocabulary = CompiledVocabulary(vocabulary)
        self.formatting = formatting
        resetTranscript()
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
            if LiveDecodeWindowPolicy.join(confirmedText, windowText).isEmpty
                || undecoded > Self.staleSampleThreshold {
                await decodeWindow(Array(samples[min(confirmedSampleCount, samples.count)...]))
            }
        }

        let finalText = emittedText()
        resetTranscript()
        onLevel?(0)
        return (finalText, samples)
    }

    /// Abort without producing a transcript (e.g. permission revoked mid-flight).
    func cancel() {
        isRunning = false
        decodeLoop?.cancel()
        decodeLoop = nil
        audioCapture.cancel()
        resetTranscript()
        onLevel?(0)
    }

    // MARK: - Decode loop

    private func startDecodeLoop() {
        decodeLoop = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                let total = self.audioCapture.sampleCount()
                if total - self.lastDecodedSampleCount >= Self.minNewSamples {
                    self.lastDecodedSampleCount = total
                    let window = self.audioCapture.snapshotTail(from: self.confirmedSampleCount)
                    await self.decodeWindow(window)
                    await self.confirmSettledPrefix(of: window)
                } else {
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
                }
            }
        }
    }

    private func decodeWindow(_ window: [Float]) async {
        guard let text = await decodedText(for: window), !text.isEmpty else { return }
        windowText = text
        onPartial?(emittedText())
    }

    /// Formatting is applied to the joined transcript, never to a lone window: a
    /// window edge is not a sentence edge, so formatting fragments would
    /// capitalise mid-sentence at every seam and split spoken commands in half.
    private func emittedText() -> String {
        TranscriptFormatter.format(
            LiveDecodeWindowPolicy.join(confirmedText, windowText),
            options: formatting
        )
    }

    /// Fold everything up to a mid-silence cut into the confirmed prefix so the
    /// next window starts short again. The prefix is decoded on its own: the
    /// window text can cover audio past the cut, which stays unconfirmed.
    private func confirmSettledPrefix(of window: [Float]) async {
        guard let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: window.count,
            frameRMS: LiveDecodeWindowPolicy.frameRMS(window)
        ), let text = await decodedText(for: Array(window[..<cut])) else { return }

        confirmedText = LiveDecodeWindowPolicy.join(confirmedText, text)
        confirmedSampleCount += cut
        windowText = ""
        lastDecodedSampleCount = confirmedSampleCount
    }

    private func decodedText(for samples: [Float]) async -> String? {
        guard !samples.isEmpty else { return nil }
        do {
            let result = try await transcription.transcribeSamples(samples, language: language, model: model)
            return vocabulary.apply(to: result.text)
        } catch {
            // Partial decode failures are non-fatal — keep the previous text.
            return nil
        }
    }

    private func resetTranscript() {
        confirmedText = ""
        confirmedSampleCount = 0
        windowText = ""
        lastDecodedSampleCount = 0
    }

}
