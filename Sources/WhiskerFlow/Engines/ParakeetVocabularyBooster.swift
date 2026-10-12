import FluidAudio
import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Dictionary biasing for Parakeet, using FluidAudio's vocabulary boosting.
///
/// Parakeet TDT has no prompt. FluidAudio instead runs a small separate CTC
/// model (parakeet-ctc-110m, ~98 MB, English-only) over the same audio,
/// spots dictionary terms acoustically, and swaps a transcript word for a term
/// only when the CTC evidence for the term beats the original word. It is a
/// rescoring pass after the TDT decode, not decode-time biasing.
///
/// Boosting never gates a dictation: until the CTC model is loaded, and on any
/// failure or overrun, the unboosted transcript is used.
actor ParakeetVocabularyBooster {
    /// The whole CTC pass (spotting plus rescoring) gets this long before the
    /// unboosted transcript is used instead.
    static let rescoreDeadline: TimeInterval = 2
    /// Audio longer than this is delivered unboosted: the pass scales with length
    /// and the file path would have to hold every sample in memory.
    static let maximumAudioSeconds: Double = 120

    private var models: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var loading: Task<(CtcModels, CtcTokenizer), Error>?
    private var session: (terms: [String], session: VocabularyBoostingSession)?
    private let load: @Sendable () async throws -> (CtcModels, CtcTokenizer)

    init(load: @escaping @Sendable () async throws -> (CtcModels, CtcTokenizer) = {
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        return (models, tokenizer)
    }) {
        self.load = load
    }

    var isReady: Bool { models != nil }

    /// Starts the one-time download and load in the background. Safe to call
    /// repeatedly; later calls join the load in flight.
    func prepare() {
        guard models == nil, loading == nil else { return }
        let load = self.load
        loading = Task { try await load() }
        Task { await finishLoading() }
    }

    private func finishLoading() async {
        guard let loading else { return }
        do {
            let (models, tokenizer) = try await loading.value
            self.models = models
            self.tokenizer = tokenizer
        } catch {
            // Leave boosting off; the next dictation retries the load.
        }
        self.loading = nil
    }

    /// The boosted transcript and the terms it applied, or nil to keep the
    /// original: not ready, nothing matched, over budget, or failed.
    func rescore(_ result: ASRResult, samples: [Float], terms: [String]) async -> ASRResult? {
        guard !terms.isEmpty, let timings = result.tokenTimings, !timings.isEmpty,
              Double(samples.count) / 16_000 <= Self.maximumAudioSeconds else { return nil }
        guard let session = await session(for: terms) else {
            prepare()
            return nil
        }
        let text = result.text
        let output = try? await withAbandoningDeadline(seconds: Self.rescoreDeadline) {
            await session.rescore(text: text, tokenTimings: timings, audioSamples: samples)
        }
        guard let rescored = output ?? nil, rescored.wasModified else { return nil }
        let applied = rescored.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
        return result.withRescoring(text: rescored.text, detected: nil, applied: applied)
    }

    private func session(for terms: [String]) async -> VocabularyBoostingSession? {
        if let session, session.terms == terms { return session.session }
        guard let models, let tokenizer else { return nil }
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
            let ids = tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        })
        guard !vocabulary.terms.isEmpty,
              let built = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models) else {
            return nil
        }
        session = (terms, built)
        return built
    }
}
