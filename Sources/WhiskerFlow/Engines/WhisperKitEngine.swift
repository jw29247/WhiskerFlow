import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Primary engine: on-device Whisper via CoreML / Neural Engine. The model is
/// loaded once and kept warm, so only the first transcription pays the load cost.
actor WhisperKitEngine: Sendable {
    private var pipe: WhisperKit?
    /// Keyed by identifier, not by `WhisperModel`, so switching between the
    /// English-only and multilingual variants of one size reloads the pipe.
    private var loadedIdentifier: String?
    private var meetingPreparation: Task<Void, Error>?
    private let decodeGate = ModelDecodeGate()

    func prepare(model: WhisperModel, language: String?) async throws {
        let identifier = model.whisperKitIdentifier(
            multilingual: WhisperModel.requiresMultilingualModel(language: language)
        )
        try await prepare(identifier: identifier, displayName: model.displayName)
    }

    /// Meeting Mode uses a pinned high-accuracy model without changing the
    /// user's lightweight push-to-talk model preference.
    func prepareMeeting(language: String?) async throws {
        if pipe != nil, loadedIdentifier == Self.meetingModelIdentifier { return }
        // Startup warm-up and recovery can arrive together. Join one model load
        // instead of compiling the same large CoreML model concurrently.
        let preparation: Task<Void, Error>
        if let pending = meetingPreparation {
            preparation = pending
        } else {
            preparation = Task {
                defer { meetingPreparation = nil }
                try await prepare(identifier: Self.meetingModelIdentifier, displayName: "WhisperKit meeting model")
            }
            meetingPreparation = preparation
        }
        do {
            try await withAbandoningDeadline(seconds: 180) { try await preparation.value }
        } catch AsyncTimeoutError.timedOut {
            // CoreML compilation is not cancellable. Let that single load finish
            // in the background; subsequent attempts join it instead of restarting.
            throw TranscriptionError.underlying("The meeting model is still preparing. The recording is saved; transcription will retry.")
        }
    }

    func transcribeMeeting(
        _ request: TranscriptionRequest
    ) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepareMeeting(language: request.language)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable("WhisperKit meeting model")
        }
        let deadline = Self.audioSeconds(at: request.audioURL)
            .map(DecodeTimeoutPolicy.timeout(forAudioSeconds:)) ?? DecodeTimeoutPolicy.maximumTimeout
        let results = try await decode(seconds: deadline) {
            try await pipe.transcribe(
                audioPath: request.audioURL.path,
                decodeOptions: Self.decodingOptions(
                    language: request.language,
                    withoutTimestamps: false,
                    wordTimestamps: true,
                    concurrentWorkerCount: 1
                )
            )
        }
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            segments: results.flatMap(\.segments).map {
                WhiskerFlowCore.TranscriptionSegment(
                    text: $0.text,
                    start: Double($0.start),
                    end: Double($0.end)
                )
            },
            language: results.first?.language ?? request.language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    private func prepare(identifier: String, displayName: String) async throws {
        if pipe != nil, loadedIdentifier == identifier { return }
        do {
            // Loading and prediction share one admission gate. Actor reentrancy
            // otherwise allows two callers with different identifiers to enter
            // separate Core ML loads while the first constructor is suspended.
            try await decodeGate.runExclusive {
                try await self.loadAndInstall(identifier: identifier)
            }
        } catch ModelDecodeGateError.occupied {
            throw TranscriptionError.underlying(
                "The previous local model operation is still finishing. The recording is saved and will retry."
            )
        } catch {
            pipe = nil
            loadedIdentifier = nil
            throw TranscriptionError.modelUnavailable(displayName)
        }
    }

    private func loadAndInstall(identifier: String) async throws {
        let downloadBase = try ModelStoragePaths.prepareWhisperKitDownloadBase()
        let localAssets = try ModelStoragePaths.prepareLocalAssets(modelIdentifier: identifier)
        // Keep meeting inference off the GPU: the pinned meeting model triggered
        // an MPSGraph shape assertion during real capture recovery. CPU/ANE
        // completed the same recovery and the bounded-window acceptance recording.
        let compute: ModelComputeOptions? = identifier == Self.meetingModelIdentifier
            ? ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            : nil
        let kit: WhisperKit
        if let localAssets {
            kit = try await WhisperKit(
                modelFolder: localAssets.modelFolder.path,
                tokenizerFolder: localAssets.tokenizerDownloadBase,
                computeOptions: compute,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
        } else {
            kit = try await WhisperKit(
                model: identifier,
                downloadBase: downloadBase,
                tokenizerFolder: downloadBase,
                computeOptions: compute,
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            )
        }
        pipe = kit
        loadedIdentifier = identifier
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepare(model: request.model, language: request.language)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable(request.model.displayName)
        }

        let deadline = Self.audioSeconds(at: request.audioURL)
            .map(DecodeTimeoutPolicy.timeout(forAudioSeconds:)) ?? DecodeTimeoutPolicy.maximumTimeout
        let results = try await decode(seconds: deadline) {
            try await pipe.transcribe(
                audioPath: request.audioURL.path,
                decodeOptions: Self.decodingOptions(
                    language: request.language,
                    withoutTimestamps: true,
                    wordTimestamps: false
                )
            )
        }

        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        let segments = results.flatMap(\.segments).map {
            WhiskerFlowCore.TranscriptionSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }

        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            segments: segments,
            language: results.first?.language ?? request.language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    /// Transcribe an in-memory 16 kHz mono float buffer using the warm pipe.
    /// Used by the live dictation loop. An empty result yields an empty string
    /// (a partial that hasn't caught any speech yet is not an error).
    func transcribe(samples: [Float], language: String?, model: WhisperModel) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepare(model: model, language: language)
        guard let pipe else {
            throw TranscriptionError.modelUnavailable(model.displayName)
        }

        // A live window is bounded by `LiveDecodeWindowPolicy.hardCapSeconds`, so it
        // gets the tight live budget rather than the file-decode budget: the release
        // path awaits these serially and the finish watchdog has to outlast them.
        let results = try await decode(seconds: DecodeTimeoutPolicy.livePartialTimeout) {
            try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodingOptions(
                    language: language,
                    withoutTimestamps: true,
                    wordTimestamps: false
                )
            )
        }

        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            language: results.first?.language ?? language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    /// Run only one Core ML decode at a time. A deadline may release the caller,
    /// but the underlying prediction is not necessarily cancellable; the gate
    /// remains occupied until that actual operation settles so a retry cannot
    /// load another model beside it.
    private func decode<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await decodeGate.run(seconds: seconds, operation: operation)
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

    static func decodingOptions(
        language: String?,
        withoutTimestamps: Bool,
        wordTimestamps: Bool,
        concurrentWorkerCount: Int? = nil
    ) -> DecodingOptions {
        // WhisperKit 0.13 derives `detectLanguage` from `!usePrefillPrompt`, so
        // auto-detect stays off unless forced on. A nil language is the only
        // case that needs it, and it always loads the multilingual weights.
        DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: withoutTimestamps,
            wordTimestamps: wordTimestamps,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: .vad
        )
    }

    static let meetingModelIdentifier = "openai_whisper-large-v3-v20240930_turbo_632MB"
}

enum ModelDecodeGateError: Error, Equatable {
    case occupied
}

actor ModelDecodeGate {
    private var activeOperationID: UUID?

    var isOccupied: Bool { activeOperationID != nil }

    func runExclusive(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard activeOperationID == nil else { throw ModelDecodeGateError.occupied }
        let operationID = UUID()
        activeOperationID = operationID
        do {
            try await operation()
            finish(operationID)
        } catch {
            finish(operationID)
            throw error
        }
    }

    func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard activeOperationID == nil else { throw ModelDecodeGateError.occupied }
        let operationID = UUID()
        activeOperationID = operationID
        let work = Task { try await operation() }
        do {
            let value = try await withAbandoningDeadline(seconds: seconds) {
                try await work.value
            }
            finish(operationID)
            return value
        } catch AsyncTimeoutError.timedOut {
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID)
            throw AsyncTimeoutError.timedOut
        } catch {
            // Treat every non-success as potentially abandoning a
            // non-cooperative provider operation. If it has already settled,
            // this clears immediately; otherwise retries remain excluded.
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID)
            throw error
        }
    }

    private func retainOccupancy<T: Sendable>(
        untilSettled work: Task<T, Error>,
        operationID: UUID
    ) {
        Task { [weak self] in
            _ = try? await work.value
            await self?.finish(operationID)
        }
    }

    private func finish(_ operationID: UUID) {
        if activeOperationID == operationID { activeOperationID = nil }
    }
}
