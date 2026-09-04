import FluidAudio
import Foundation
import WhiskerFlowCore

/// Fast on-device speech recognition backed by Parakeet TDT v3/Core ML.
///
/// FluidAudio owns the model cache under Application Support. Keeping the
/// manager alive means model loading and Core ML compilation happen during the
/// app warm-up rather than on the release-to-paste path.
actor ParakeetTDTv3Engine: Sendable {
    private var manager: AsrManager?

    func prepare() async throws {
        guard SystemInfo.isAppleSilicon else {
            throw TranscriptionError.engineUnavailable(.parakeetTDTv3)
        }
        if let manager, await manager.isAvailable { return }

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                encoderPrecision: .int8
            )
            let loadedManager = AsrManager(config: .default)
            try await loadedManager.loadModels(models)
            manager = loadedManager
        } catch {
            manager = nil
            throw TranscriptionError.modelUnavailable("Parakeet TDT v3")
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await prepare()
        guard let manager else {
            throw TranscriptionError.modelUnavailable("Parakeet TDT v3")
        }

        do {
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(
                request.audioURL,
                decoderState: &decoderState
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

            let segments = result.tokenTimings?.map {
                TranscriptionSegment(
                    text: $0.token,
                    start: $0.startTime,
                    end: $0.endTime
                )
            } ?? []
            return TranscriptionResult(
                text: text.plainTranscriptText,
                segments: segments,
                language: request.language,
                duration: result.duration
            )
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
    }
}
