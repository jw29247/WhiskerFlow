import Foundation
import LiteRTLM
import OpenTelemetryApi
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum LocalCleanupError: Error {
    case notReady, busy, invalidOutput, invalidDownload
}

protocol DictationCleaning: Sendable {
    func clean(_ request: DictationCleanupRequest) async throws -> String
}

/// Owns a single Metal engine. Reentrant calls never queue extra generations.
actor LocalCleanupEngine: DictationCleaning {
    private var engine: Engine?
    private var busy = false

    func prepare(modelURL: URL) async throws {
        guard engine == nil else { return }
        guard !busy else { throw LocalCleanupError.busy }
        busy = true
        defer { busy = false }
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        let cache = modelURL.deletingLastPathComponent().appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let config = try EngineConfig(modelPath: modelURL.path, backend: .gpu,
                                      maxNumTokens: 4096, cacheDir: cache.path,
                                      speculativeDecodingConfig: .init(mode: .on))
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        try Task.checkCancellation()
        // Pay first-use Metal/prefill/decode costs before reporting ready. This
        // synthetic conversation is discarded; dictations still start fresh.
        let warmup = try await candidate.createConversation(with: conversationConfig())
        try await withTaskCancellationHandler {
            _ = try await warmup.sendMessage(Message(DictationCleanupRequest(text: "Hello.").prompt), maxOutputTokens: 32)
            try Task.checkCancellation()
        } onCancel: {
            try? warmup.cancel()
        }
        engine = candidate
    }

    func unload() { engine = nil }

    func clean(_ request: DictationCleanupRequest) async throws -> String {
        try Task.checkCancellation()
        guard let engine else { throw LocalCleanupError.notReady }
        guard !busy else { throw LocalCleanupError.busy }
        guard request.isEligible else { throw LocalCleanupError.invalidOutput }
        busy = true
        defer { busy = false }
        let conversation = try await engine.createConversation(with: conversationConfig())
        // The synchronous native generation stays inside this actor until it
        // finishes, even if the deadline abandons the caller. This prevents a
        // timed-out generation overlapping the next request on the same engine.
        return try await withTaskCancellationHandler {
            let outputLimit = 1800
            let response = try await conversation.sendMessage(Message(request.prompt), maxOutputTokens: outputLimit)
            try Task.checkCancellation()
            let usage = try conversation.getBenchmarkInfo()
            let attributes: [String: OpenTelemetryApi.AttributeValue] = [
                "gen_ai.provider.name": .string("google"),
                "gen_ai.request.model": .string(LocalCleanupModel.identifier),
                "app.gen_ai.use_case": .string("dictation_cleanup")
            ]
            Observability.cleanupInputTokens.add(value: usage.lastPrefillTokenCount, attributes: attributes)
            Observability.cleanupOutputTokens.add(value: usage.lastDecodeTokenCount, attributes: attributes)
            guard usage.lastDecodeTokenCount < outputLimit,
                  let cleaned = request.validated(response.toString),
                  try conversation.getTokenCount() < 4096 else { throw LocalCleanupError.invalidOutput }
            return cleaned
        } onCancel: {
            try? conversation.cancel()
        }
    }

    private func conversationConfig() throws -> ConversationConfig {
        ConversationConfig(
            systemMessage: Message(DictationCleanupRequest.instructions),
            samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0)
        )
    }
}
