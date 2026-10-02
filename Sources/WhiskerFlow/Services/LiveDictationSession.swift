import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Dictation capture using the app-owned HAL input capture service.
///
/// While the key is held, audio streams into a 16 kHz float buffer and,
/// optionally, a preview loop shows the latest words in the HUD. On `finish()`
/// the captured samples are returned for the release-time decode.
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

    private var previewLoop: Task<Void, Never>?
    private var language: String?
    private var vocabulary = Vocabulary()
    /// Compiled on first use, off the hotkey path, then reused for every partial.
    private var compiledVocabulary: CompiledVocabulary?
    private var tone: WritingTone = .formal
    private var recognizeCorrections = false
    private var formatting = FormattingOptions()
    /// Spool of the session in progress, known from `start()` so the caller can
    /// file the audio for recovery before the release-time decode runs.
    private(set) var currentAudioURL: URL?
    private var isRunning = false
    /// Bumped by every `start()`. A preview that was in flight when the session
    /// restarted belongs to the previous generation and must not reach the HUD.
    private var generation = 0

    private static let sampleRate = 16_000.0
    /// Preview again once this much new audio has accumulated since the last pass.
    private static let minNewSamples = Int(sampleRate * 0.4)
    /// Live preview decodes only the recent tail: the HUD shows the latest words,
    /// and a window under Parakeet's 15 s model input stays a single pass.
    private static let previewWindowSamples = Int(sampleRate * 12)

    init(transcription: TranscriptionService) {
        self.transcription = transcription
        audioCapture.keepsCaptureReady = true
        audioCapture.onLevel = { [weak self] level, peak in self?.onLevel?(level, peak) }
        audioCapture.onConfigurationChange = { [weak self] in self?.onConfigurationChange?() }
    }

    /// Begin capturing and (with a `previewEngine`) previewing. Throws if the mic
    /// engine can't start. Requires microphone permission to already be granted.
    func start(
        selection: AudioInputSelection,
        language: String?,
        vocabulary: Vocabulary,
        formatting: FormattingOptions,
        tone: WritingTone = .formal,
        recognizeCorrections: Bool = false,
        previewEngine: TranscriptionEngineKind? = nil
    ) async throws {
        self.language = language
        self.vocabulary = vocabulary
        compiledVocabulary = nil
        self.tone = tone
        self.recognizeCorrections = recognizeCorrections
        self.formatting = formatting
        generation &+= 1
        currentAudioURL = nil
        do {
            let audioURL = try AudioFileWriter.makeRecordingURL()
            try await audioCapture.start(selection: selection, spoolTo: audioURL)
            currentAudioURL = audioURL
            isRunning = true
        } catch {
            isRunning = false
            throw error
        }

        if let previewEngine {
            startPreviewLoop(engine: previewEngine, generation: generation)
        }
    }

    /// Stop capture and return the captured samples for the release-time decode.
    ///
    /// `storageFailed` means the recording file stopped accepting audio (for
    /// example a full disk), so everything after that point is missing.
    func finish(
        reason: CaptureStopReason = .userReleased
    ) -> (samples: [Float], conversionFailures: Int, audioURL: URL?, totalSampleCount: Int, storageFailed: Bool) {
        isRunning = false
        // Not awaited: the release-time decode waits only for a preview already
        // inside the model, never for the loop to wind down.
        previewLoop?.cancel()
        previewLoop = nil
        currentAudioURL = nil
        let captured = audioCapture.stop(reason: reason)
        onLevel?(0, 0)
        return (captured.samples, captured.conversionFailureCount, captured.audioURL,
                captured.totalSampleCount, captured.storageFailed)
    }

    /// Refines the tone once a slower lookup (a browser tab) resolves. Applies to
    /// previews from now on.
    func setTone(_ tone: WritingTone) {
        self.tone = tone
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
        previewLoop?.cancel()
        previewLoop = nil
        audioCapture.cancel()
        currentAudioURL = nil
        onLevel?(0, 0)
    }

    // MARK: - Preview

    /// Show what is being heard, so the user can see dictation working.
    /// Display only — never part of the result.
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

    private func compiled() -> CompiledVocabulary {
        if let compiledVocabulary { return compiledVocabulary }
        let compiled = CompiledVocabulary(vocabulary)
        compiledVocabulary = compiled
        return compiled
    }
}
