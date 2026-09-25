import FluidAudio
@preconcurrency import AVFoundation
import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Fast on-device speech recognition backed by Parakeet TDT v3/Core ML.
///
/// FluidAudio owns the model cache under Application Support. Keeping the
/// manager alive means model loading and Core ML compilation happen during the
/// app warm-up rather than on the release-to-paste path.
actor ParakeetTDTv3Engine: Sendable {
    private var manager: AsrManager?
    private var preparation: (id: UUID, task: Task<AsrManager, Error>)?
    /// The warm-up or live-preview decode in flight. At most one runs, and never
    /// alongside a real decode, so the shared manager sees one decode at a time.
    private var backgroundInference: (id: UUID, task: Task<Void, Never>)?
    private var activeDecodes = 0
    /// One second of silence: enough to run the encoder, decoder and joint once.
    private static let warmUpSamples = [Float](repeating: 0, count: 16_000)
    private let loadManager: @Sendable () async throws -> AsrManager
    /// A Core ML prediction that wedges never returns, and `AsrManager` is an
    /// actor, so every later decode would queue behind it. Decodes are
    /// time-boxed and admitted one at a time; while an abandoned one is still
    /// running, new decodes fail fast so the caller can fall back.
    private let decodeGate = ModelDecodeGate()
    private let preparationWait: TimeInterval
    /// Dictionary biasing; see `ParakeetVocabularyBooster`.
    let booster = ParakeetVocabularyBooster()

    init(
        preparationWait: TimeInterval = DecodeTimeoutPolicy.modelPreparationWait,
        loadManager: @escaping @Sendable () async throws -> AsrManager = {
            let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
    ) {
        self.preparationWait = preparationWait
        self.loadManager = loadManager
    }

    /// True while a timed-out (possibly wedged) decode still holds the model,
    /// so any further decode would fail the same way.
    var isDecodeWedged: Bool {
        get async { await decodeGate.isHeldByAbandonedOperation }
    }

    func prepare() async throws {
        guard SystemInfo.isAppleSilicon else {
            throw TranscriptionError.engineUnavailable(.parakeetTDTv3)
        }
        if manager != nil { return }

        // Actors are reentrant at awaits: a first dictation can arrive while
        // launch warm-up is loading. Both callers must share that load.
        let task: Task<AsrManager, Error>
        let preparationID: UUID
        if let preparation {
            task = preparation.task
            preparationID = preparation.id
        } else {
            preparationID = UUID()
            let loader = loadManager
            task = Task { try await loader() }
            preparation = (preparationID, task)
        }

        do {
            manager = try await task.value
            if preparation?.id == preparationID { preparation = nil }
        } catch {
            if preparation?.id == preparationID { preparation = nil }
            throw TranscriptionError.modelUnavailable("Parakeet TDT v3")
        }
    }

    /// Core ML and the Neural Engine go cold within about a minute of idle: the
    /// first decode after a pause measured 0.4–4 s against 80 ms warm for the same
    /// 11 s clip. A throwaway decode while the user is still speaking moves that
    /// cost off the release-to-paste path. No-op until the model is loaded.
    func warmUpInference() {
        guard let manager, backgroundInference == nil, activeDecodes == 0 else { return }
        let id = UUID()
        let gate = decodeGate
        let task = Task { [weak self] in
            // Gated and time-boxed like a real decode, so a wedged warm-up cannot
            // hold up the decode that waits for it in `beginDecode()`.
            _ = try? await gate.run(seconds: DecodeTimeoutPolicy.timeout(forAudioSeconds: 1)) {
                var state = try TdtDecoderState()
                return try await manager.transcribe(Self.warmUpSamples, decoderState: &state)
            }
            await self?.finishBackgroundInference(id)
        }
        backgroundInference = (id, task)
    }

    /// A best-effort transcript of recent audio for the HUD while the user is
    /// still speaking. Returns nil instead of queueing when the model is busy;
    /// the delivered transcript always comes from the full decode on release.
    func previewTranscription(samples: [Float], language: String?) async -> String? {
        guard let manager, backgroundInference == nil, activeDecodes == 0 else { return nil }
        let id = UUID()
        let gate = decodeGate
        let seconds = DecodeTimeoutPolicy.timeout(forAudioSeconds: Double(samples.count) / 16_000)
        let decode = Task<String?, Never> {
            // Time-boxed so a wedged preview cannot block the real decode queued
            // behind it in `beginDecode()`.
            let decoded = try? await gate.run(seconds: seconds, operation: {
                var state = try TdtDecoderState()
                return try await manager.transcribe(samples, decoderState: &state)
            })
            guard let decoded else { return nil }
            return try? Self.result(decoded, language: language).text
        }
        backgroundInference = (id, Task { _ = await decode.value })
        let text = await decode.value
        finishBackgroundInference(id)
        return text
    }

    private func finishBackgroundInference(_ id: UUID) {
        if backgroundInference?.id == id { backgroundInference = nil }
    }

    /// Real decodes never interleave with a warm-up or preview inside the shared
    /// manager: wait for one in flight, and block new ones until done.
    private func beginDecode() async {
        await backgroundInference?.task.value
        activeDecodes += 1
    }

    private func endDecode() { activeDecodes -= 1 }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let manager = try await preparedManager()
        await beginDecode()
        defer { endDecode() }
        let audioURL = request.audioURL
        let seconds = Self.audioSeconds(at: audioURL)
            .map { DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: $0) } ?? DecodeTimeoutPolicy.maximumTimeout

        do {
            // Let FluidAudio preserve decoder context across its bounded,
            // disk-backed chunks. Independent 30-second decodes can return an
            // empty window and discard speech recovered from the rest of a file.
            try Task.checkCancellation()
            let decoded = try await decode(seconds: seconds) {
                var decoderState = try TdtDecoderState()
                return try await manager.transcribeDiskBacked(audioURL, decoderState: &decoderState)
            }
            try Task.checkCancellation()
            let boosted = await boost(decoded, terms: request.hints.terms(for: .parakeetTDTv3)) {
                // Only read back into memory when boosting will actually run.
                try? AudioConverter().resampleAudioFile(audioURL)
            }
            return try Self.result(boosted, language: request.language)
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
    }

    /// Bounded wait for the model. A first-run download
    /// can outlast it; the load keeps going and the caller falls back meanwhile.
    private func preparedManager() async throws -> AsrManager {
        if manager == nil {
            do {
                try await withAbandoningDeadline(seconds: preparationWait) { try await self.prepare() }
            } catch AsyncTimeoutError.timedOut {
                throw TranscriptionError.timedOut(seconds: Int(preparationWait))
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            }
        }
        guard let manager else { throw TranscriptionError.modelUnavailable("Parakeet TDT v3") }
        return manager
    }

    private func decode<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            // Back-to-back dictations and retries wait their turn; only a wedged
            // (abandoned) decode makes them fail fast.
            return try await decodeGate.run(
                seconds: seconds, waitingUpTo: DecodeTimeoutPolicy.gateQueueWait, operation: operation)
        } catch AsyncTimeoutError.timedOut {
            throw TranscriptionError.timedOut(seconds: Int(seconds))
        } catch ModelDecodeGateError.occupied {
            throw TranscriptionError.underlying(
                "The previous local transcription is still finishing. The recording is saved and will retry."
            )
        }
    }

    private static func audioSeconds(at url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// Capture already produces mono 16 kHz samples. Decode those directly,
    /// leaving WAV encoding and history persistence off the delivery path.
    func transcribe(samples: [Float], model: WhisperModel, language: String?,
                    hints: RecognizerHints = .none) async throws -> TranscriptionResult {
        let manager = try await preparedManager()
        await beginDecode()
        defer { endDecode() }
        let seconds = DecodeTimeoutPolicy.longFormTimeout(forAudioSeconds: Double(samples.count) / 16_000)
        do {
            try Task.checkCancellation()
            let result = try await decode(seconds: seconds) {
                var decoderState = try TdtDecoderState()
                return try await manager.transcribe(samples, decoderState: &decoderState)
            }
            try Task.checkCancellation()
            let boosted = await boost(result, terms: hints.terms(for: .parakeetTDTv3)) { samples }
            return try Self.result(boosted, language: language)
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
    }

    /// Runs the vocabulary rescoring pass when there are terms and the CTC model
    /// is ready; otherwise starts loading it for next time and returns `result`.
    private func boost(_ result: ASRResult, terms: [String], samples: () -> [Float]?) async -> ASRResult {
        guard !terms.isEmpty else { return result }
        guard await booster.isReady, result.duration <= ParakeetVocabularyBooster.maximumAudioSeconds else {
            await booster.prepare()
            return result
        }
        guard let audio = samples() else { return result }
        return await booster.rescore(result, samples: audio, terms: terms) ?? result
    }

    private static func result(_ result: ASRResult, language: String?) throws -> TranscriptionResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        let segments = result.tokenTimings.map(buildWordTimings)?.map {
            TranscriptionSegment(text: $0.word, start: $0.startTime, end: $0.endTime)
        } ?? []
        return TranscriptionResult(
            text: text.plainTranscriptText,
            segments: segments,
            language: language,
            duration: result.duration
        )
    }
}
