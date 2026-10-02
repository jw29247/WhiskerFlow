import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct TranscriptionOutcome: Sendable {
  let result: TranscriptionResult
  let engine: TranscriptionEngineKind
}

/// Picks the configured engine, warms it up, and falls back to Apple Speech
/// when the primary engine is unavailable or fails (e.g. offline first run).
actor TranscriptionService {
  private let parakeetTDTv3 = ParakeetTDTv3Engine()
  private let appleSpeech = AppleSpeechEngine()
  /// `AppleDictationEngine` on macOS 26; stored untyped so the app still runs on 14.
  private let appleDictationEngine: Any? = {
    if #available(macOS 26.0, *) { return AppleDictationEngine() }
    return nil
  }()
  /// Tests only: stands in for every engine's recogniser.
  typealias Recognizer = @Sendable (TranscriptionRequest, TranscriptionEngineKind) async throws -> TranscriptionResult
  private let recognizerOverride: Recognizer?

  init(recognizerOverride: Recognizer? = nil) {
    self.recognizerOverride = recognizerOverride
  }

  @discardableResult
  func prepare(kind: TranscriptionEngineKind, language: String?) async -> Bool {
    switch kind {
    case .parakeetTDTv3:
      do {
        try await parakeetTDTv3.prepare()
        // The first inference after loading pays Core ML's one-time setup.
        await parakeetTDTv3.warmUpInference()
        return true
      } catch {
        return false
      }
    case .appleSpeech:
      return await appleSpeech.requestAuthorization()
    case .appleDictation:
      guard #available(macOS 26.0, *), let engine = appleDictationEngine as? AppleDictationEngine,
            let language else { return false }
      return (try? await engine.prepare(locale: language)) != nil
    }
  }

  /// Wakes the dictation model while the user is still speaking; see
  /// `ParakeetTDTv3Engine.warmUpInference()`.
  func warmUpDictationInference(kind: TranscriptionEngineKind) async {
    guard kind == .parakeetTDTv3 else { return }
    await parakeetTDTv3.warmUpInference()
  }

  /// Live HUD text for engines that decode only on release; nil when unsupported
  /// or when the model is busy.
  func previewDictation(samples: [Float], kind: TranscriptionEngineKind, language: String?) async -> String? {
    guard kind == .parakeetTDTv3 else { return nil }
    return await parakeetTDTv3.previewTranscription(samples: samples, language: language)
  }

  /// Loads what dictionary biasing needs for `kind` ahead of the first
  /// dictation. Only Parakeet has anything to load (its CTC boosting model).
  func prepareHints(_ hints: RecognizerHints, kind: TranscriptionEngineKind) async {
    guard kind == .parakeetTDTv3, !hints.terms(for: .parakeetTDTv3).isEmpty else { return }
    await parakeetTDTv3.booster.prepare()
  }

  func requestAppleSpeechAuthorization() async -> Bool {
    await appleSpeech.requestAuthorization()
  }

  /// Identifies the recogniser in meeting checkpoints and Atlas receipts.
  static let meetingModelIdentifier = TranscriptionEngineKind.parakeetTDTv3.modelIdentifier

  /// Meetings use the dictation model: one Parakeet instance, so a meeting
  /// window never evicts it. Its word timings are grouped into phrases, the
  /// unit speaker labels are matched on.
  func transcribeMeeting(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    var result = try await parakeetTDTv3.transcribe(TranscriptionRequest(audioURL: audioURL, language: language))
    result.segments = TranscriptPhraseSegmenter.phrases(from: result.segments)
    return result
  }

  /// Warm-up waits for the model however long a first-run download and
  /// compile take, so a slow Mac reports ready instead of a false failure.
  /// Cancelling the caller stops the wait; the load keeps going.
  func prepareMeeting(language: String?) async -> Bool {
    do {
      try await parakeetTDTv3.prepare()
      return true
    } catch {
      return false
    }
  }

  func transcribe(
    audioURL: URL,
    kind: TranscriptionEngineKind,
    language: String?,
    allowAppleFallback: Bool,
    capturedSamples: [Float]? = nil,
    hints: RecognizerHints = .none
  ) async throws -> TranscriptionOutcome {
    let request = TranscriptionRequest(
      audioURL: audioURL,
      language: language,
      hints: hints
    )

    do {
      if let recognizerOverride {
        return TranscriptionOutcome(result: try await recognizerOverride(request, kind), engine: kind)
      }
      if kind == .parakeetTDTv3, let capturedSamples {
        do {
          let result = try await parakeetTDTv3.transcribe(
            samples: capturedSamples, language: language, hints: hints)
          return TranscriptionOutcome(result: result, engine: kind)
        } catch {
          if Task.isCancelled { throw error }
          // A deadline or a still-busy model would fail the file decode the same
          // way after another full wait; go straight to the Apple fallback.
          if case TranscriptionError.timedOut = error { throw error }
          if await parakeetTDTv3.isDecodeWedged { throw error }
          // Audio and a retryable record are already durable. Retain the file
          // decoder and Apple fallback if the direct sample path fails.
        }
      }
      let result = try await primaryTranscribe(request, kind: kind)
      return TranscriptionOutcome(result: result, engine: kind)
    } catch {
      if Task.isCancelled { throw error }
      if allowAppleFallback, kind != .appleSpeech {
        if let fallback = try? await appleSpeech.transcribe(request) {
          return TranscriptionOutcome(result: fallback, engine: .appleSpeech)
        }
      }
      throw error
    }
  }

  private func primaryTranscribe(
    _ request: TranscriptionRequest,
    kind: TranscriptionEngineKind
  ) async throws -> TranscriptionResult {
    switch kind {
    case .parakeetTDTv3:
      return try await parakeetTDTv3.transcribe(request)
    case .appleSpeech:
      return try await appleSpeech.transcribe(request)
    case .appleDictation:
      guard #available(macOS 26.0, *), let engine = appleDictationEngine as? AppleDictationEngine else {
        throw TranscriptionError.engineUnavailable(.appleDictation)
      }
      return try await engine.transcribe(request, locale: request.language ?? "en-US")
    }
  }
}
