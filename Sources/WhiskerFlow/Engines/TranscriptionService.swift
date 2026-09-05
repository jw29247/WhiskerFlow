import Foundation
import SpeakerKit
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
  private let whisperKit = WhisperKitEngine()
  private let appleSpeech = AppleSpeechEngine()
  private var meetingSpeakerKit: SpeakerKit?

  @discardableResult
  func prepare(kind: TranscriptionEngineKind, model: WhisperModel, language: String?) async -> Bool {
    switch kind {
    case .parakeetTDTv3:
      do {
        try await parakeetTDTv3.prepare()
        return true
      } catch {
        return false
      }
    case .whisperKit:
      do {
        try await whisperKit.prepare(model: model, language: language)
        return true
      } catch {
        return false
      }
    case .appleSpeech:
      return await appleSpeech.requestAuthorization()
    case .whisperCLI:
      return true
    }
  }

  func requestAppleSpeechAuthorization() async -> Bool {
    await appleSpeech.requestAuthorization()
  }

  /// Transcribe an in-memory 16 kHz mono float buffer with the warm WhisperKit
  /// pipe (single shared model instance — no extra load). Drives live dictation.
  func transcribeSamples(_ samples: [Float], language: String?, model: WhisperModel) async throws
    -> TranscriptionResult {
    try await whisperKit.transcribe(samples: samples, language: language, model: model)
  }

  func transcribeMeeting(audioURL: URL, language: String?) async throws -> TranscriptionResult {
    try await whisperKit.transcribeMeeting(
      TranscriptionRequest(
        audioURL: audioURL,
        language: language,
        model: .medium
      )
    )
  }

  func prepareMeeting(language: String?) async -> Bool {
    do {
      try await whisperKit.prepareMeeting(language: language)
      _ = try await ensureMeetingSpeakerKit()
      return true
    } catch {
      meetingSpeakerKit = nil
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
    if meetingSpeakerKit == nil {
      meetingSpeakerKit = try await SpeakerKit(
        PyannoteConfig(
          download: true,
          load: true,
          verbose: false,
          fullRedundancy: false
        )
      )
    }
    guard let meetingSpeakerKit else { throw TranscriptionError.modelUnavailable("SpeakerKit") }
    try await meetingSpeakerKit.ensureModelsLoaded()
    return meetingSpeakerKit
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
    model: WhisperModel,
    language: String?,
    cliConfiguration: WhisperConfiguration,
    allowAppleFallback: Bool,
    capturedSamples: [Float]? = nil
  ) async throws -> TranscriptionOutcome {
    let request = TranscriptionRequest(
      audioURL: audioURL,
      language: language,
      model: model
    )

    do {
      if kind == .parakeetTDTv3, let capturedSamples {
        do {
          let result = try await parakeetTDTv3.transcribe(samples: capturedSamples, model: model, language: language)
          return TranscriptionOutcome(result: result, engine: kind)
        } catch {
          if Task.isCancelled { throw error }
          // Audio and a retryable record are already durable. Retain the file
          // decoder and Apple fallback if the direct sample path fails.
        }
      }
      let result = try await primaryTranscribe(
        request, kind: kind, cliConfiguration: cliConfiguration)
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
    kind: TranscriptionEngineKind,
    cliConfiguration: WhisperConfiguration
  ) async throws -> TranscriptionResult {
    switch kind {
    case .parakeetTDTv3:
      return try await parakeetTDTv3.transcribe(request)
    case .whisperKit:
      return try await whisperKit.transcribe(request)
    case .appleSpeech:
      return try await appleSpeech.transcribe(request)
    case .whisperCLI:
      return try await WhisperCLIEngine(configuration: cliConfiguration).transcribe(request)
    }
  }
}
