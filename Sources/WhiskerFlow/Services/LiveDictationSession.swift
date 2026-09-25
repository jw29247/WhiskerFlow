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
    private var previewLoop: Task<Void, Never>?
    private var language: String?
    private var model: WhisperModel = .tiny
    private var vocabulary = Vocabulary()
    /// Compiled on first use, off the hotkey path, then reused for every partial.
    private var compiledVocabulary: CompiledVocabulary?
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
    /// Live preview decodes only the recent tail: the HUD shows the latest words,
    /// and a window under Parakeet's 15 s model input stays a single pass.
    private static let previewWindowSamples = Int(sampleRate * 12)
    /// On release, if more than this much audio went undecoded (only happens when
    /// decoding fell behind real time on a long hold), do one final clean pass.
    private static let staleSampleThreshold = Int(sampleRate * 1.5)

    init(transcription: TranscriptionService) {
        self.transcription = transcription
        audioCapture.keepsCaptureReady = true
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
        recognizeCorrections: Bool = false,
        previewEngine: TranscriptionEngineKind? = nil
    ) throws {
        self.language = language
        self.model = model
        self.vocabulary = vocabulary
        compiledVocabulary = nil
        self.style = style
        self.recognizeCorrections = recognizeCorrections
        self.formatting = formatting
        generation &+= 1
        resetTranscript()
        reportedDecodeFailure = false
        isStreaming = streaming
        do {
            let audioURL = try AudioFileWriter.makeRecordingURL()
            try audioCapture.start(selection: selection, spoolTo: audioURL)
            isRunning = true
        } catch {
            isRunning = false
            isStreaming = false
            throw error
        }

        if streaming {
            startDecodeLoop(generation: generation)
        } else if let previewEngine {
            startPreviewLoop(engine: previewEngine, generation: generation)
        }
    }

    /// Stop capture and return the freshest transcript plus the captured samples.
    func finish(
        reason: CaptureStopReason = .userReleased
    ) async -> (text: String, samples: [Float], conversionFailures: Int, rawText: String,
                audioURL: URL?, totalSampleCount: Int) {
        let myGeneration = generation
        isRunning = false
        // Not awaited: the release-time decode waits only for a preview already
        // inside the model, never for the loop to wind down.
        previewLoop?.cancel()
        previewLoop = nil
        let loop = decodeLoop
        decodeLoop = nil
        let completeTailWasResident = audioCapture.hasResidentSamples(from: confirmedSampleCount)
        let captured = audioCapture.stop(reason: reason)
        await loop?.value
        let samples = captured.samples

        if isStreaming, generation == myGeneration {
            // A confirm pass throws away the window text it had already decoded past
            // the cut, so an empty window with audio still after it always needs one
            // more pass — otherwise a release right after the final phrase loses it.
            // The other case is decoding having lagged badly on a long hold.
            if let finalSamples = Self.finalDecodeSamples(
                captured: captured,
                confirmedSampleCount: confirmedSampleCount,
                lastDecodedSampleCount: lastDecodedSampleCount,
                windowIsEmpty: windowText.isEmpty
            ) {
                await decodeWindow(finalSamples, generation: myGeneration)
            }
        }

        // A `start()` during the teardown (the finish watchdog releases the
        // coordinator without waiting for us) means the state now belongs to a newer
        // session: hand back nothing rather than wiping its transcript.
        guard generation == myGeneration else {
            return ("", samples, captured.conversionFailureCount, "", captured.audioURL, captured.totalSampleCount)
        }

        guard completeTailWasResident else {
            resetTranscript()
            onLevel?(0, 0)
            return ("", samples, captured.conversionFailureCount, "", captured.audioURL, captured.totalSampleCount)
        }

        let rawText = LiveDecodeWindowPolicy.join(confirmedText, windowText)
        let finalText = emittedText()
        resetTranscript()
        onLevel?(0, 0)
        return (finalText, samples, captured.conversionFailureCount, rawText, captured.audioURL, captured.totalSampleCount)
    }

    /// Echo cancellation for engines built from now on; see `AudioCaptureService.voiceProcessing`.
    var voiceProcessing: Bool {
        get { audioCapture.voiceProcessing }
        set { audioCapture.voiceProcessing = newValue }
    }

    /// Build the next capture's engine in the background so a hotkey press only
    /// has to start it.
    func prepareCapture(selection: AudioInputSelection) {
        audioCapture.prepareCapture(for: selection)
    }

    func invalidatePreparedCapture() {
        audioCapture.invalidatePreparedCapture()
    }

    /// Abort without producing a transcript (e.g. permission revoked mid-flight).
    func cancel() {
        isRunning = false
        generation &+= 1
        decodeLoop?.cancel()
        decodeLoop = nil
        previewLoop?.cancel()
        previewLoop = nil
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

    /// For engines that transcribe on release: show what is being heard, so the
    /// user can see dictation working. Display only — never part of the result.
    private func startPreviewLoop(engine: TranscriptionEngineKind, generation myGeneration: Int) {
        previewLoop = Task { @MainActor [weak self] in
            var lastPreviewed = 0
            while let self, self.isRunning, self.generation == myGeneration, !Task.isCancelled {
                let total = self.audioCapture.sampleCount()
                guard total - lastPreviewed >= Self.minNewSamples else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                lastPreviewed = total
                let window = self.audioCapture.snapshotTail(from: max(0, total - Self.previewWindowSamples))
                guard let text = await self.transcription.previewDictation(
                    samples: window, kind: engine, language: self.language),
                    !text.isEmpty, !Task.isCancelled, self.isRunning, self.generation == myGeneration
                else { continue }
                self.onPartial?(AssistantTextProcessing.process(
                    text, style: self.style, vocabulary: self.compiled(),
                    formatting: self.formatting, recognizeCorrections: self.recognizeCorrections))
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
            style: style, vocabulary: compiled(), formatting: formatting, recognizeCorrections: recognizeCorrections)
    }

    private func compiled() -> CompiledVocabulary {
        if let compiledVocabulary { return compiledVocabulary }
        let compiled = CompiledVocabulary(vocabulary)
        compiledVocabulary = compiled
        return compiled
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

    nonisolated static func finalDecodeSamples(
        captured: CapturedAudio,
        confirmedSampleCount: Int,
        lastDecodedSampleCount: Int,
        windowIsEmpty: Bool
    ) -> [Float]? {
        let undecoded = captured.totalSampleCount - lastDecodedSampleCount
        guard windowIsEmpty || undecoded > staleSampleThreshold else { return nil }
        let localStart = max(0, confirmedSampleCount - captured.residentStartSample)
        guard localStart <= captured.samples.count else { return nil }
        return Array(captured.samples[localStart...])
    }

}
