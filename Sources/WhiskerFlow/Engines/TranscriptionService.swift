import Foundation
import SpeakerKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct TranscriptionOutcome: Sendable {
  let result: TranscriptionResult
  let engine: TranscriptionEngineKind
}

struct MeetingAudioWindow: Sendable {
  let offsetSeconds: Double
  let samples: [Float]
}

/// Picks the configured engine, warms it up, and falls back to Apple Speech
/// when the primary engine is unavailable or fails (e.g. offline first run).
actor TranscriptionService {
  private let parakeetTDTv3 = ParakeetTDTv3Engine()
  private let appleSpeech = AppleSpeechEngine()
  private var meetingSpeakerKit: SpeakerKit?
  /// The one in-flight SpeakerKit download/load; overlapping warm-ups and
  /// diarization join it instead of fetching pyannote twice into one folder.
  private var meetingSpeakerKitLoad: Task<SpeakerKit, Error>?
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
      _ = try await ensureMeetingSpeakerKit()
      return true
    } catch {
      return false
    }
  }

  /// Diarizes bounded windows so a long meeting does not require one massive
  /// system-track sample array. SpeakerKit's centroids carry stable local
  /// labels across windows; a conservative cosine-distance match avoids
  /// inventing a name when a window cannot be linked confidently.
  func diarizeMeeting(
    nextWindow: @escaping @Sendable () async throws -> MeetingAudioWindow?
  ) async throws -> [SpeakerSegment] {
    let speakerKit = try await ensureMeetingSpeakerKit()
    var centroids: [[Float]] = []
    var centroidCounts: [Int] = []
    var segments: [SpeakerSegment] = []

    while let window = try await nextWindow() {
      try Task.checkCancellation()
      guard !window.samples.isEmpty else { continue }
      let result = try await speakerKit.diarize(audioArray: window.samples)
      var localToGlobal: [Int: Int] = [:]
      var usedGlobalIDs = Set<Int>()

      for localID in result.speakerCentroidEmbeddings.keys.sorted() {
        guard let centroid = result.speakerCentroidEmbeddings[localID] else { continue }
        let nearest = centroids.enumerated().compactMap { index, existing -> (Int, Float)? in
          guard !usedGlobalIDs.contains(index), existing.count == centroid.count,
                !existing.isEmpty else { return nil }
          return (index, cosineDistance(centroid, existing))
        }.min { $0.1 < $1.1 }

        let globalID: Int
        if let nearest, nearest.1 <= Self.meetingSpeakerCentroidDistanceThreshold {
          globalID = nearest.0
          usedGlobalIDs.insert(globalID)
          let count = centroidCounts[globalID]
          let updated = zip(centroids[globalID], centroid).map { old, next in
            (old * Float(count) + next) / Float(count + 1)
          }
          centroids[globalID] = updated
          centroidCounts[globalID] = count + 1
        } else {
          globalID = centroids.count
          centroids.append(centroid)
          centroidCounts.append(1)
          usedGlobalIDs.insert(globalID)
    }
        localToGlobal[localID] = globalID
      }

      for segment in result.segments {
        guard let localID = segment.speaker.speakerId else { continue }
        let globalID: Int
        if let mapped = localToGlobal[localID] {
          globalID = mapped
        } else {
          globalID = centroids.count
          localToGlobal[localID] = globalID
          usedGlobalIDs.insert(globalID)
          centroids.append([])
          centroidCounts.append(0)
        }
        segments.append(
          SpeakerSegment(
            speaker: .speakerId(globalID),
            startTime: segment.startTime + Float(window.offsetSeconds),
            endTime: segment.endTime + Float(window.offsetSeconds),
            frameRate: segment.frameRate,
            transcription: segment.transcription,
            speakerWords: segment.speakerWords
          )
        )
      }
    }
    return segments.sorted { $0.startTime < $1.startTime }
  }

  private static let meetingSpeakerCentroidDistanceThreshold: Float = 0.35

  private func ensureMeetingSpeakerKit() async throws -> SpeakerKit {
    let speakerKit: SpeakerKit
    if let meetingSpeakerKit {
      speakerKit = meetingSpeakerKit
    } else {
      let load: Task<SpeakerKit, Error>
      if let pending = meetingSpeakerKitLoad {
        load = pending
      } else {
        load = Task {
          try await SpeakerKit(
            PyannoteConfig(
              download: true,
              load: true,
              verbose: false,
              fullRedundancy: false
            )
          )
        }
        meetingSpeakerKitLoad = load
      }
      do {
        let loaded = try await withAbandoningCancellation { try await load.value }
        if meetingSpeakerKitLoad == load { meetingSpeakerKitLoad = nil }
        speakerKit = meetingSpeakerKit ?? loaded
        meetingSpeakerKit = speakerKit
      } catch {
        // A cancelled caller only stopped waiting; the load stays joinable.
        if !(error is CancellationError), meetingSpeakerKitLoad == load { meetingSpeakerKitLoad = nil }
        throw error
      }
    }
    do {
      try await speakerKit.ensureModelsLoaded()
    } catch {
      // Rebuild SpeakerKit on the next attempt rather than retrying a broken one.
      if meetingSpeakerKit === speakerKit { meetingSpeakerKit = nil }
      throw error
    }
    return speakerKit
  }

  private func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
    var dot: Float = 0
    var lhsMagnitude: Float = 0
    var rhsMagnitude: Float = 0
    for (left, right) in zip(lhs, rhs) {
      dot += left * right
      lhsMagnitude += left * left
      rhsMagnitude += right * right
    }
    guard lhsMagnitude > 0, rhsMagnitude > 0 else { return .infinity }
    return max(0, min(2, 1 - dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())))
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
    }
  }
}
