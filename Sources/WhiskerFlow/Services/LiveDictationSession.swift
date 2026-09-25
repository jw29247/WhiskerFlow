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
    private var tone: WritingTone = .formal
    private var recognizeCorrections = false
    private var hints: RecognizerHints = .none
    private var formatting = FormattingOptions()
    private var confirmedText = ""
    private var confirmedSampleCount = 0
    private var windowText = ""
    /// Absolute position in the capture buffer where the latest decode pass
    /// started. Paces the loop only: it moves before the pass succeeds.
    private var lastDecodedSampleCount = 0
    /// Absolute end of the audio `windowText` was actually decoded from. Only a
    /// successful decode moves it, so `finish()` can tell exactly what the
    /// transcript is missing.
    private var windowEndSampleCount = 0
    /// Spool of the session in progress, known from `start()` so the caller can
    /// file the audio for recovery before the release-time decode runs.
    private(set) var currentAudioURL: URL?
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
    /// Undecoded audio on release gets one final pass when any 100 ms frame of it
    /// reaches this RMS (about -46 dBFS). It sits below both the live cut's speech
    /// line and the HUD's "too quiet" warning: a skipped pass loses the last
    /// words, while an unneeded one costs only a short decode.
    private static let finalPassSpeechRMS: Float = LiveDecodeWindowPolicy.silenceRMS / 2

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
        tone: WritingTone = .formal,
        recognizeCorrections: Bool = false,
        hints: RecognizerHints = .none,
        previewEngine: TranscriptionEngineKind? = nil
    ) throws {
        self.language = language
        self.model = model
        self.vocabulary = vocabulary
        compiledVocabulary = nil
        self.tone = tone
        self.recognizeCorrections = recognizeCorrections
        self.hints = hints
        self.formatting = formatting
        generation &+= 1
        resetTranscript()
        reportedDecodeFailure = false
        isStreaming = streaming
        currentAudioURL = nil
        do {
            let audioURL = try AudioFileWriter.makeRecordingURL()
            try audioCapture.start(selection: selection, spoolTo: audioURL)
            currentAudioURL = audioURL
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
    ///
    /// `coversAllAudio` is true only when `text` was decoded from every audible
    /// sample of the capture. When it is false — the final pass failed or timed
    /// out, the tail rolled out of memory, or the session never streamed — the
    /// caller must transcribe the file rather than trust `text`.
    /// `storageFailed` means the recording file stopped accepting audio (for
    /// example a full disk), so everything after that point is missing.
    ///
    /// Everything the result depends on is snapshotted before the first await, so
    /// a `start()` during the teardown (the finish watchdog releases the
    /// coordinator without waiting for us) cannot erase this session's transcript
    /// — and this finish never touches the newer session's state.
    func finish(
        reason: CaptureStopReason = .userReleased
    ) async -> (text: String, samples: [Float], conversionFailures: Int, rawText: String,
                audioURL: URL?, totalSampleCount: Int, coversAllAudio: Bool, storageFailed: Bool) {
        let myGeneration = generation
        let streaming = isStreaming
        let options = (language: language, model: model, tone: tone, vocabulary: vocabulary,
                       formatting: formatting, recognizeCorrections: recognizeCorrections)
        isRunning = false
        // Not awaited: the release-time decode waits only for a preview already
        // inside the model, never for the loop to wind down.
        previewLoop?.cancel()
        previewLoop = nil
        currentAudioURL = nil
        let loop = decodeLoop
        decodeLoop = nil
        let captured = audioCapture.stop(reason: reason)
        var transcript = (confirmedText: confirmedText, confirmedSampleCount: confirmedSampleCount,
                          windowText: windowText, windowEnd: windowEndSampleCount)
        await loop?.value
        if generation == myGeneration {
            // The pass that was in flight at release may have landed a fresher window.
            transcript = (confirmedText, confirmedSampleCount, windowText, windowEndSampleCount)
        }
        let samples = captured.samples
        defer {
            if generation == myGeneration {
                resetTranscript()
                onLevel?(0, 0)
            }
        }

        // The live transcript can only be completed from resident audio. When the
        // unconfirmed tail already rolled out of memory, a final decode would be
        // thrown away, so skip it and let the caller transcribe the file.
        guard streaming, transcript.confirmedSampleCount >= captured.residentStartSample else {
            return ("", samples, captured.conversionFailureCount, "", captured.audioURL,
                    captured.totalSampleCount, false, captured.storageFailed)
        }

        var coversAllAudio = true
        if let finalSamples = Self.finalDecodeSamples(
            captured: captured,
            confirmedSampleCount: transcript.confirmedSampleCount,
            lastDecodedSampleCount: transcript.windowEnd,
            windowIsEmpty: transcript.windowText.isEmpty
        ) {
            if let text = await decodedText(for: finalSamples, language: options.language, model: options.model) {
                // The pass saw the whole unconfirmed tail; an empty result means it
                // held no further words, not that the earlier window was wrong.
                if !text.isEmpty { transcript.windowText = text }
            } else {
                coversAllAudio = false
            }
        }

        let rawText = LiveDecodeWindowPolicy.join(transcript.confirmedText, transcript.windowText)
        let finalText = AssistantTextProcessing.process(rawText, tone: options.tone, vocabulary: options.vocabulary,
            formatting: options.formatting, recognizeCorrections: options.recognizeCorrections)
        return (finalText, samples, captured.conversionFailureCount, rawText, captured.audioURL,
                captured.totalSampleCount, coversAllAudio && !captured.storageFailed, captured.storageFailed)
    }

    /// Refines the tone once a slower lookup (a browser tab) resolves. Applies to
    /// partials from now on and to `finish()`.
    func setTone(_ tone: WritingTone) {
        self.tone = tone
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
        currentAudioURL = nil
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
                    let windowStart = self.confirmedSampleCount
                    let window = self.audioCapture.snapshotTail(from: windowStart)
                    await self.decodeWindow(window, startingAt: windowStart, generation: myGeneration)
                    // Released mid-pass: a confirm pass now would only re-decode the
                    // prefix and empty the window, forcing `finish()` into yet another
                    // decode before the paste. `finish()` covers the tail itself.
                    guard self.isRunning, self.generation == myGeneration else { break }
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
                    text, tone: self.tone, vocabulary: self.compiled(),
                    formatting: self.formatting, recognizeCorrections: self.recognizeCorrections))
            }
        }
    }

    private func decodeWindow(_ window: [Float], startingAt windowStart: Int, generation myGeneration: Int) async {
        guard let text = await decodedText(for: window), !text.isEmpty else { return }
        guard generation == myGeneration else { return }
        windowText = text
        windowEndSampleCount = windowStart + window.count
        onPartial?(emittedText())
    }

    /// Formatting is applied to the joined transcript, never to a lone window: a
    /// window edge is not a sentence edge, so formatting fragments would
    /// capitalise mid-sentence at every seam and split spoken commands in half.
    private func emittedText() -> String {
        AssistantTextProcessing.process(LiveDecodeWindowPolicy.join(confirmedText, windowText),
            tone: tone, vocabulary: compiled(), formatting: formatting, recognizeCorrections: recognizeCorrections)
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
        windowEndSampleCount = confirmedSampleCount
        lastDecodedSampleCount = confirmedSampleCount
    }

    private func decodedText(for samples: [Float]) async -> String? {
        await decodedText(for: samples, language: language, model: model)
    }

    private func decodedText(for samples: [Float], language: String?, model: WhisperModel) async -> String? {
        guard !samples.isEmpty else { return nil }
        do {
            let result = try await transcription.transcribeSamples(samples, language: language, model: model, hints: hints)
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
        windowEndSampleCount = 0
        lastDecodedSampleCount = 0
    }

    /// The samples a final pass must decode on release, or nil when the transcript
    /// already covers every audible sample. `lastDecodedSampleCount` is the
    /// absolute end of the audio the current window text was decoded from (not
    /// where a pass merely started). An empty window covers nothing past the
    /// confirmed prefix. Any audible audio beyond that coverage — even the last
    /// word spoken a fraction of a second before release — gets one pass over the
    /// whole unconfirmed tail, so the window never splits a word.
    nonisolated static func finalDecodeSamples(
        captured: CapturedAudio,
        confirmedSampleCount: Int,
        lastDecodedSampleCount: Int,
        windowIsEmpty: Bool
    ) -> [Float]? {
        let covered = windowIsEmpty ? confirmedSampleCount : max(confirmedSampleCount, lastDecodedSampleCount)
        guard captured.totalSampleCount > covered else { return nil }
        let localStart = max(0, confirmedSampleCount - captured.residentStartSample)
        guard localStart < captured.samples.count else { return nil }
        let uncoveredStart = min(captured.samples.count, max(localStart, covered - captured.residentStartSample))
        let uncovered = Array(captured.samples[uncoveredStart...])
        guard LiveDecodeWindowPolicy.frameRMS(uncovered).contains(where: { $0 >= finalPassSpeechRMS }) else { return nil }
        return Array(captured.samples[localStart...])
    }

}
