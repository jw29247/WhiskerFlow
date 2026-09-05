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
    /// Called on the main actor with a normalized 0...1 input level and the
    /// buffer's absolute peak.
    var onLevel: ((Float, Float) -> Void)?
    /// Called after AVFoundation reports that the active input configuration changed.
    var onConfigurationChange: (() -> Void)?

    private var decodeLoop: Task<Void, Never>?
    private var language: String?
    private var model: WhisperModel = .tiny
    private var vocabulary = Vocabulary()
    private var style: WritingStyle = .standard
    private var recognizeCorrections = false
    private var formatting = FormattingOptions()
    private var confirmedText = ""
    private var confirmedSampleCount = 0
    private var windowText = ""
    /// Absolute position in the capture buffer that the transcript reaches.
    private var lastDecodedSampleCount = 0
    private var isRunning = false
    private var isStreaming = false
    private var reportedDecodeFailure = false
    /// Bumped by every `start()`. A decode pass that was in flight when the session
    /// restarted belongs to the previous generation and must not touch the
    /// transcript, so a late-returning decode can never resurrect an old loop or
    /// mix its text into the new session.
    private var generation = 0

    private static let sampleRate = 16_000.0
    /// Re-decode once this much new audio has accumulated since the last pass.
    private static let minNewSamples = Int(sampleRate * 0.4)
    /// On release, if more than this much audio went undecoded (only happens when
    /// decoding fell behind real time on a long hold), do one final clean pass.
    private static let staleSampleThreshold = Int(sampleRate * 1.5)

    init(transcription: TranscriptionService) {
        self.transcription = transcription
        audioCapture.onLevel = { [weak self] level, peak in self?.onLevel?(level, peak) }
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
        streaming: Bool,
        style: WritingStyle = .standard,
        recognizeCorrections: Bool = false
    ) throws {
        self.language = language
        self.model = model
        self.vocabulary = vocabulary
        self.style = style
        self.recognizeCorrections = recognizeCorrections
        self.formatting = formatting
        generation &+= 1
        resetTranscript()
        reportedDecodeFailure = false
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
            startDecodeLoop(generation: generation)
        }
    }

    /// Stop capture and return the freshest transcript plus the captured samples.
    func finish(
        reason: CaptureStopReason = .userReleased
    ) async -> (text: String, samples: [Float], conversionFailures: Int, rawText: String) {
        let myGeneration = generation
        isRunning = false
        let loop = decodeLoop
        decodeLoop = nil
        let captured = audioCapture.stop(reason: reason)
        await loop?.value
        let samples = captured.samples

        if isStreaming, generation == myGeneration {
            // A confirm pass throws away the window text it had already decoded past
            // the cut, so an empty window with audio still after it always needs one
            // more pass — otherwise a release right after the final phrase loses it.
            // The other case is decoding having lagged badly on a long hold.
            let undecoded = samples.count - lastDecodedSampleCount
            if windowText.isEmpty || undecoded > Self.staleSampleThreshold {
                await decodeWindow(
                    Array(samples[min(confirmedSampleCount, samples.count)...]),
                    generation: myGeneration
                )
            }
        }

        // A `start()` during the teardown (the finish watchdog releases the
        // coordinator without waiting for us) means the state now belongs to a newer
        // session: hand back nothing rather than wiping its transcript.
        guard generation == myGeneration else {
            return ("", samples, captured.conversionFailureCount, "")
        }

        let rawText = LiveDecodeWindowPolicy.join(confirmedText, windowText)
        let finalText = emittedText()
        resetTranscript()
        onLevel?(0, 0)
        return (finalText, samples, captured.conversionFailureCount, rawText)
    }

    /// Abort without producing a transcript (e.g. permission revoked mid-flight).
    func cancel() {
        isRunning = false
        generation &+= 1
        decodeLoop?.cancel()
        decodeLoop = nil
        audioCapture.cancel()
        resetTranscript()
        onLevel?(0, 0)
    }

    // MARK: - Decode loop

    private func startDecodeLoop(generation myGeneration: Int) {
        decodeLoop = Task { @MainActor [weak self] in
            while let self, self.isRunning, self.generation == myGeneration, !Task.isCancelled {
                let total = self.audioCapture.sampleCount()
                if total - self.lastDecodedSampleCount >= Self.minNewSamples {
                    self.lastDecodedSampleCount = total
                    let window = self.audioCapture.snapshotTail(from: self.confirmedSampleCount)
                    await self.decodeWindow(window, generation: myGeneration)
                    await self.confirmSettledPrefix(of: window, generation: myGeneration)
                } else {
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
                }
            }
        }
    }

    private func decodeWindow(_ window: [Float], generation myGeneration: Int) async {
        guard let text = await decodedText(for: window), !text.isEmpty else { return }
        guard generation == myGeneration else { return }
        windowText = text
        onPartial?(emittedText())
    }

    /// Formatting is applied to the joined transcript, never to a lone window: a
    /// window edge is not a sentence edge, so formatting fragments would
    /// capitalise mid-sentence at every seam and split spoken commands in half.
    private func emittedText() -> String {
        AssistantTextProcessing.process(LiveDecodeWindowPolicy.join(confirmedText, windowText),
            style: style, vocabulary: vocabulary, formatting: formatting, recognizeCorrections: recognizeCorrections)
    }

    /// Fold everything up to a mid-silence cut into the confirmed prefix so the
    /// next window starts short again. The prefix is decoded on its own: the
    /// window text can cover audio past the cut, which stays unconfirmed and is
    /// dropped here — `finish()` re-decodes an empty window's tail for exactly that
    /// reason, so a release seconds after a cut still keeps the words spoken since.
    private func confirmSettledPrefix(of window: [Float], generation myGeneration: Int) async {
        guard let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: window.count,
            frameRMS: LiveDecodeWindowPolicy.frameRMS(window)
        ), let text = await decodedText(for: Array(window[..<cut])) else { return }
        guard generation == myGeneration else { return }

        confirmedText = LiveDecodeWindowPolicy.join(confirmedText, text)
        confirmedSampleCount += cut
        windowText = ""
        lastDecodedSampleCount = confirmedSampleCount
    }

    private func decodedText(for samples: [Float]) async -> String? {
        guard !samples.isEmpty else { return nil }
        do {
            let result = try await transcription.transcribeSamples(samples, language: language, model: model)
            return result.text
        } catch {
            // Partial decode failures are non-fatal — keep the previous text. The
            // decode loop runs several times a second, so report once per session.
            if !reportedDecodeFailure {
                reportedDecodeFailure = true
                DiagnosticsService.capture(
                    error: error,
                    category: "model",
                    code: "live_decode_failed"
                )
            }
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
