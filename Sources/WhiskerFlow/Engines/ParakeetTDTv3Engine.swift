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

    init(loadManager: @escaping @Sendable () async throws -> AsrManager = {
        let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }) {
        self.loadManager = loadManager
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
        let task = Task { [weak self] in
            if var state = try? TdtDecoderState() {
                _ = try? await manager.transcribe(Self.warmUpSamples, decoderState: &state)
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
        let decode = Task<String?, Never> {
            guard var state = try? TdtDecoderState(),
                  let decoded = try? await manager.transcribe(samples, decoderState: &state) else { return nil }
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
        try await prepare()
        await beginDecode()
        defer { endDecode() }
        guard let manager else {
            throw TranscriptionError.modelUnavailable("Parakeet TDT v3")
        }

        do {
            // Let FluidAudio preserve decoder context across its bounded,
            // disk-backed chunks. Independent 30-second decodes can return an
            // empty window and discard speech recovered from the rest of a file.
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState()
            let decoded = try await manager.transcribeDiskBacked(
                request.audioURL, decoderState: &decoderState)
            try Task.checkCancellation()
            return try Self.result(decoded, language: request.language)
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
    }

    /// Capture already produces mono 16 kHz samples. Decode those directly,
    /// leaving WAV encoding and history persistence off the delivery path.
    func transcribe(samples: [Float], model: WhisperModel, language: String?) async throws -> TranscriptionResult {
        try await prepare()
        await beginDecode()
        defer { endDecode() }
        guard let manager else { throw TranscriptionError.modelUnavailable("Parakeet TDT v3") }
        do {
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            try Task.checkCancellation()
            return try Self.result(result, language: language)
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
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
