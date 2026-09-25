import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Primary engine: on-device Whisper via CoreML / Neural Engine. The model is
/// loaded once and kept warm, so only the first transcription pays the load cost.
actor WhisperKitEngine: Sendable {
    /// The dictation model. Meeting Mode keeps its own slot below: sharing one
    /// made every meeting window evict the dictation model and vice versa, each
    /// swap reloading a multi-GB Core ML model.
    private var pipe: WhisperKit?
    /// Keyed by identifier, not by `WhisperModel`, so switching between the
    /// English-only and multilingual variants of one size reloads the pipe.
    private var loadedIdentifier: String?
    private var meetingPipe: WhisperKit?
    /// At most one load per identifier. Launch warm-up, a first dictation and a
    /// settings change can all ask for the same model; they join one load.
    private var pendingLoads: [String: Task<Void, Error>] = [:]
    private let decodeGate = ModelDecodeGate()

    /// Waits for the model to finish loading, however long that takes; a
    /// cancelled caller stops waiting while the load itself carries on.
    func prepare(model: WhisperModel, language: String?) async throws {
        try await prepare(identifier: Self.identifier(model: model, language: language), displayName: model.displayName)
    }

    /// Meeting Mode uses a pinned high-accuracy model without changing the
    /// user's lightweight push-to-talk model preference. A nil wait blocks until
    /// the load settles (warm-up); decodes pass a bound so they can retry later.
    func prepareMeeting(
        language: String?,
        waitingUpTo seconds: TimeInterval? = DecodeTimeoutPolicy.modelPreparationWait
    ) async throws {
        if meetingPipe != nil { return }
        guard let seconds else {
            try await prepare(identifier: Self.meetingModelIdentifier, displayName: "WhisperKit meeting model")
            return
        }
        do {
            try await withAbandoningDeadline(seconds: seconds) {
                try await self.prepare(identifier: Self.meetingModelIdentifier, displayName: "WhisperKit meeting model")
            }
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
        guard let pipe = meetingPipe else {
            throw TranscriptionError.modelUnavailable("WhisperKit meeting model")
        }
        let deadline = Self.audioSeconds(at: request.audioURL)
            .map(DecodeTimeoutPolicy.timeout(forAudioSeconds:)) ?? DecodeTimeoutPolicy.maximumTimeout
        let results = try await decode(seconds: deadline, queueWait: DecodeTimeoutPolicy.gateQueueWait) {
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

    private static func identifier(model: WhisperModel, language: String?) -> String {
        model.whisperKitIdentifier(
            multilingual: WhisperModel.requiresMultilingualModel(language: language)
        )
    }

    private func installedPipe(for identifier: String) -> WhisperKit? {
        if identifier == Self.meetingModelIdentifier { return meetingPipe }
        return loadedIdentifier == identifier ? pipe : nil
    }

    private func prepare(identifier: String, displayName: String) async throws {
        if installedPipe(for: identifier) != nil { return }
        let load = startLoad(identifier: identifier)
        do {
            try await withAbandoningCancellation { try await load.value }
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            // Only a successful load installs a pipe, so a failed one leaves any
            // model already loaded (in either slot) in place.
            throw TranscriptionError.modelUnavailable(displayName)
        }
    }

    /// Dictation decodes wait only briefly for the load (see
    /// `DecodeTimeoutPolicy.dictationModelLoadWait`) so the Apple fallback runs
    /// during a first-run download; the load keeps going for the next attempt.
    private func prepareForDictationDecode(model: WhisperModel, language: String?) async throws {
        if installedPipe(for: Self.identifier(model: model, language: language)) != nil { return }
        do {
            try await withAbandoningDeadline(seconds: DecodeTimeoutPolicy.dictationModelLoadWait) {
                try await self.prepare(model: model, language: language)
            }
        } catch AsyncTimeoutError.timedOut {
            throw TranscriptionError.underlying(
                "The \(model.displayName) model is still loading. The recording is saved and will retry."
            )
        }
    }

    /// Queue wait for a dictation file decode: a whole decode window normally,
    /// but only briefly while a model load (which can take minutes) is pending.
    private var dictationQueueWait: TimeInterval {
        pendingLoads.isEmpty ? DecodeTimeoutPolicy.gateQueueWait : DecodeTimeoutPolicy.dictationModelLoadWait
    }

    /// Start the load for `identifier`, or return the one already running.
    /// Loads queue on the shared gate rather than failing while another load or
    /// decode holds it, so two warm-ups arriving together both succeed.
    @discardableResult
    private func startLoad(identifier: String) -> Task<Void, Error> {
        if let pending = pendingLoads[identifier] { return pending }
        let gate = decodeGate
        let load = Task {
            defer { pendingLoads[identifier] = nil }
            try await gate.runQueued(waitingUpTo: nil) {
                try await self.loadAndInstall(identifier: identifier)
            }
        }
        pendingLoads[identifier] = load
        return load
    }

    private func loadAndInstall(identifier: String) async throws {
        if installedPipe(for: identifier) != nil { return }
        let downloadBase = try ModelStoragePaths.prepareWhisperKitDownloadBase()
        let localAssets = try ModelStoragePaths.prepareLocalAssets(modelIdentifier: identifier)
        // Keep meeting inference off the GPU: the pinned meeting model triggered
        // an MPSGraph shape assertion during real capture recovery. CPU/ANE
        // completed the same recovery and the bounded-window acceptance recording.
        let compute: ModelComputeOptions? = identifier == Self.meetingModelIdentifier
            ? ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            : nil
        var kit: WhisperKit?
        if let localAssets {
            // A local folder can be incomplete (an interrupted download). Fall
            // through to the downloading load, which fetches what is missing.
            kit = try? await WhisperKit(
                modelFolder: localAssets.modelFolder.path,
                tokenizerFolder: localAssets.tokenizerDownloadBase,
                computeOptions: compute,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
        }
        let loaded: WhisperKit
        if let kit {
            loaded = kit
        } else {
            loaded = try await WhisperKit(
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
        if identifier == Self.meetingModelIdentifier {
            meetingPipe = loaded
        } else {
            pipe = loaded
            loadedIdentifier = identifier
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepareForDictationDecode(model: request.model, language: request.language)
        guard let pipe = installedPipe(for: Self.identifier(model: request.model, language: request.language)) else {
            throw TranscriptionError.modelUnavailable(request.model.displayName)
        }

        let deadline = Self.audioSeconds(at: request.audioURL)
            .map(DecodeTimeoutPolicy.timeout(forAudioSeconds:)) ?? DecodeTimeoutPolicy.maximumTimeout
        let prompt = promptTokens(for: request.hints.terms(for: .whisperKit), pipe: pipe)
        let results = try await decode(seconds: deadline, queueWait: dictationQueueWait) {
            try await pipe.transcribe(
                audioPath: request.audioURL.path,
                decodeOptions: Self.decodingOptions(
                    language: request.language,
                    withoutTimestamps: true,
                    wordTimestamps: false,
                    promptTokens: prompt
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
    func transcribe(samples: [Float], language: String?, model: WhisperModel,
                    promptTerms: [String] = []) async throws -> WhiskerFlowCore.TranscriptionResult {
        // A live pass never waits for a model load: that load is unbounded and
        // the release path awaits the loop. Start it in the background instead;
        // the file decode at release joins it for a bounded wait.
        let identifier = Self.identifier(model: model, language: language)
        guard let pipe = installedPipe(for: identifier) else {
            startLoad(identifier: identifier)
            throw TranscriptionError.modelUnavailable(model.displayName)
        }

        // A live window is bounded by `LiveDecodeWindowPolicy.hardCapSeconds`, so it
        // gets the tight live budget rather than the file-decode budget: the release
        // path awaits these serially and the finish watchdog has to outlast them.
        let prompt = promptTokens(for: promptTerms, pipe: pipe)
        let results = try await decode(seconds: DecodeTimeoutPolicy.livePartialTimeout) {
            try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodingOptions(
                    language: language,
                    withoutTimestamps: true,
                    wordTimestamps: false,
                    promptTokens: prompt
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

    /// Decode one bounded file window with timestamps for deterministic overlap
    /// ownership. This remains separate from the timestamp-free live API above.
    func transcribeFileWindow(
        samples: [Float], language: String?, model: WhisperModel, promptTerms: [String] = []
    ) async throws -> WhiskerFlowCore.TranscriptionResult {
        try await prepareForDictationDecode(model: model, language: language)
        guard let pipe = installedPipe(for: Self.identifier(model: model, language: language)) else {
            throw TranscriptionError.modelUnavailable(model.displayName)
        }
        let prompt = promptTokens(for: promptTerms, pipe: pipe)
        let results = try await decode(seconds: DecodeTimeoutPolicy.timeout(
            forAudioSeconds: Double(samples.count) / 16_000
        ), queueWait: dictationQueueWait) {
            try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: Self.fileWindowDecodingOptions(language: language, promptTokens: prompt)
            )
        }
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return WhiskerFlowCore.TranscriptionResult(
            text: text.plainTranscriptText,
            segments: Self.timedWordSegments(from: results.flatMap(\.segments).flatMap {
                ($0.words ?? []).map {
                    (text: $0.word, start: Double($0.start), end: Double($0.end))
                }
            }),
            language: results.first?.language ?? language,
            duration: results.first?.timings.inputAudioSeconds
        )
    }

    /// Run only one Core ML decode at a time. A deadline may release the caller,
    /// but the underlying prediction is not necessarily cancellable; the gate
    /// remains occupied until that actual operation settles so a retry cannot
    /// load another model beside it. Live partials pass no queue wait and fail
    /// fast; file decodes wait their turn behind a load or another decode.
    private func decode<T: Sendable>(
        seconds: Double,
        queueWait: TimeInterval = 0,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await decodeGate.run(seconds: seconds, waitingUpTo: queueWait, operation: operation)
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
        concurrentWorkerCount: Int? = nil,
        promptTokens: [Int]? = nil
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
            promptTokens: promptTokens,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: .vad
        )
    }

    static func fileWindowDecodingOptions(language: String?, promptTokens: [Int]? = nil) -> DecodingOptions {
        decodingOptions(
            language: language,
            withoutTimestamps: false,
            wordTimestamps: true,
            concurrentWorkerCount: 1,
            promptTokens: promptTokens
        )
    }

    /// Whisper reads `<|startofprev|>` tokens as the transcript that came before
    /// this audio, so a short glossary there nudges it towards those spellings.
    /// Whole terms are added until the budget is reached; the budget is far
    /// below the 223-token limit because a long previous-text context is what
    /// makes Whisper continue it rather than transcribe (see
    /// docs/validation/2026-09-25-dictionary-biasing.md).
    static let maximumPromptTokens = 64

    private var promptCache: (terms: [String], tokens: [Int]?)?

    private func promptTokens(for terms: [String], pipe: WhisperKit) -> [Int]? {
        guard !terms.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        if let promptCache, promptCache.terms == terms { return promptCache.tokens }
        let tokens = Self.promptTokens(for: terms, tokenizer: tokenizer)
        promptCache = (terms, tokens)
        return tokens
    }

    static func promptTokens(for terms: [String], tokenizer: WhisperTokenizer) -> [Int]? {
        let special = tokenizer.specialTokens.specialTokenBegin
        var kept: [String] = []
        var tokens: [Int] = []
        for term in terms {
            let candidate = tokenizer.encode(text: " " + (kept + [term]).joined(separator: ", ") + ".")
                .filter { $0 < special }
            guard candidate.count <= maximumPromptTokens else { break }
            kept.append(term)
            tokens = candidate
        }
        return tokens.isEmpty ? nil : tokens
    }

    static func timedWordSegments(
        from words: [(text: String, start: Double, end: Double)]
    ) -> [WhiskerFlowCore.TranscriptionSegment] {
        words.map {
            WhiskerFlowCore.TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
        }
    }

    static let meetingModelIdentifier = "openai_whisper-large-v3-v20240930_turbo_632MB"
}

enum ModelDecodeGateError: Error, Equatable {
    case occupied
}

actor ModelDecodeGate {
    private var activeOperationID: UUID?
    /// FIFO queue of callers waiting for the gate; `finish` hands it straight
    /// to the next one so a fail-fast caller cannot jump the queue.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Set while the holder is an operation its caller already abandoned (a
    /// possibly wedged prediction). Waiters, bounded or not, fail fast instead
    /// of sitting out their wait behind something that may never return.
    private var abandonedOperationID: UUID?

    var isOccupied: Bool { activeOperationID != nil }
    /// A timed-out operation still holds the gate.
    var isHeldByAbandonedOperation: Bool { abandonedOperationID != nil }

    /// Fails with `occupied` instead of waiting when anything holds the gate.
    func runExclusive(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await runQueued(waitingUpTo: 0, operation: operation)
    }

    /// Like `runExclusive`, but waits up to `seconds` (nil: indefinitely) for
    /// the gate before failing with `occupied`. Behind an abandoned holder every
    /// caller fails with `occupied`.
    func runQueued(
        waitingUpTo seconds: TimeInterval?,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let operationID = try await acquire(waitingUpTo: seconds)
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
        waitingUpTo queueSeconds: TimeInterval = 0,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationID = try await acquire(waitingUpTo: queueSeconds)
        let work = Task { try await operation() }
        do {
            let value = try await withAbandoningDeadline(seconds: seconds) {
                try await work.value
            }
            finish(operationID)
            return value
        } catch AsyncTimeoutError.timedOut {
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID, abandoned: true)
            throw AsyncTimeoutError.timedOut
        } catch {
            // Treat every non-success as potentially abandoning a
            // non-cooperative provider operation. If it has already settled,
            // this clears immediately; otherwise retries remain excluded.
            work.cancel()
            retainOccupancy(untilSettled: work, operationID: operationID, abandoned: false)
            throw error
        }
    }

    private func acquire(waitingUpTo seconds: TimeInterval?) async throws -> UUID {
        let operationID = UUID()
        if activeOperationID == nil, waiters.isEmpty {
            activeOperationID = operationID
            return operationID
        }
        // Nothing queues behind an abandoned (possibly wedged) holder, not even an
        // unbounded load: it may never return, and every later caller would join it.
        if abandonedOperationID != nil { throw ModelDecodeGateError.occupied }
        if let seconds, seconds <= 0 { throw ModelDecodeGateError.occupied }
        let expiry = seconds.map { seconds in
            Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
                await self?.dropWaiter(operationID, error: ModelDecodeGateError.occupied)
            }
        }
        defer { expiry?.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((operationID, continuation))
                }
            }
        } onCancel: {
            Task { await self.dropWaiter(operationID, error: CancellationError()) }
        }
        return operationID
    }

    private func dropWaiter(_ operationID: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == operationID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func retainOccupancy<T: Sendable>(
        untilSettled work: Task<T, Error>,
        operationID: UUID,
        abandoned: Bool
    ) {
        if abandoned, activeOperationID == operationID {
            abandonedOperationID = operationID
            // Callers already queued behind it fail now too, as later ones will.
            let queued = waiters
            waiters.removeAll()
            queued.forEach { $0.continuation.resume(throwing: ModelDecodeGateError.occupied) }
        }
        Task { [weak self] in
            _ = try? await work.value
            await self?.finish(operationID)
        }
    }

    private func finish(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        abandonedOperationID = nil
        if waiters.isEmpty {
            activeOperationID = nil
        } else {
            let next = waiters.removeFirst()
            activeOperationID = next.id
            next.continuation.resume()
        }
    }
}
