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

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await prepare()
        guard let manager else {
            throw TranscriptionError.modelUnavailable("Parakeet TDT v3")
        }

        do {
            let file = try AVAudioFile(forReading: request.audioURL)
            let rate = file.processingFormat.sampleRate
            let windowFrames = AVAudioFrameCount(rate * 30)
            var assembler = BoundedTranscriptAssembler()
            let ranges = BoundedDecodeWindowPolicy.frameRanges(totalFrames: file.length, sampleRate: rate)
            for range in ranges {
                try Task.checkCancellation()
                let start = range.lowerBound
                file.framePosition = start
                let count = AVAudioFrameCount(range.count)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    throw CocoaError(.fileReadUnknown)
                }
                try file.read(into: pcm, frameCount: count)
                guard let channel = pcm.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
                var decoderState = try TdtDecoderState()
                let decoded: TranscriptionResult
                do {
                    decoded = try await Self.result(
                        manager.transcribe(samples, decoderState: &decoderState),
                        language: request.language
                    )
                } catch TranscriptionError.emptyTranscript {
                    guard BoundedDecodeWindowPolicy.containsAudibleActivity(samples) else { continue }
                    throw TranscriptionError.underlying(
                        "Audible recording audio was not transcribed. The recording is saved and will retry."
                    )
                }
                if file.length <= AVAudioFramePosition(windowFrames) { return decoded }
                let offset = Double(start) / rate
                let lower = start == 0 ? offset : offset + 0.5
                let isLast = range.upperBound >= file.length
                let upper = isLast ? .infinity : offset + Double(count) / rate - 0.5
                try assembler.append(decoded, offsetSeconds: offset, ownership: lower..<upper,
                                     requiresTimings: true)
            }
            return try assembler.finish(language: request.language, duration: Double(file.length) / rate)
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
