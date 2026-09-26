import Foundation
@preconcurrency import AVFoundation
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
  private let whisperKit = WhisperKitEngine()
  private let appleSpeech = AppleSpeechEngine()
  private var meetingSpeakerKit: SpeakerKit?
  /// The one in-flight SpeakerKit download/load; overlapping warm-ups and
  /// diarization join it instead of fetching pyannote twice into one folder.
  private var meetingSpeakerKitLoad: Task<SpeakerKit, Error>?

  @discardableResult
  func prepare(kind: TranscriptionEngineKind, model: WhisperModel, language: String?) async -> Bool {
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

  /// Transcribe an in-memory 16 kHz mono float buffer with the warm WhisperKit
  /// pipe (single shared model instance — no extra load). Drives live dictation.
  func transcribeSamples(_ samples: [Float], language: String?, model: WhisperModel,
                         hints: RecognizerHints = .none) async throws
    -> TranscriptionResult {
    try await whisperKit.transcribe(samples: samples, language: language, model: model,
                                    promptTerms: hints.terms(for: .whisperKit))
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

  /// Warm-up waits for the meeting model however long a first-run download
  /// and compile take, so a slow Mac reports ready instead of a false failure.
  /// Cancelling the caller stops the wait; the load keeps going.
  func prepareMeeting(language: String?) async -> Bool {
    do {
      try await whisperKit.prepareMeeting(language: language, waitingUpTo: nil)
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
    model: WhisperModel,
    language: String?,
    cliConfiguration: WhisperConfiguration,
    allowAppleFallback: Bool,
    capturedSamples: [Float]? = nil,
    hints: RecognizerHints = .none
  ) async throws -> TranscriptionOutcome {
    let request = TranscriptionRequest(
      audioURL: audioURL,
      language: language,
      model: model,
      hints: hints
    )

    do {
      if kind == .whisperKit, capturedSamples == nil {
        return await TranscriptionOutcome(
          result: try transcribeWhisperFileBounded(request), engine: kind)
      }
      if kind == .parakeetTDTv3, let capturedSamples {
        do {
          let result = try await parakeetTDTv3.transcribe(
            samples: capturedSamples, model: model, language: language, hints: hints)
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

  private func transcribeWhisperFileBounded(_ request: TranscriptionRequest) async throws
    -> TranscriptionResult {
    let file = try AVAudioFile(forReading: request.audioURL)
    let rate = file.processingFormat.sampleRate
    let windowFrames = AVAudioFrameCount(rate * 30)
    var assembler = BoundedTranscriptAssembler()
    let ranges = BoundedDecodeWindowPolicy.frameRanges(totalFrames: file.length, sampleRate: rate)
    let ownership = BoundedDecodeWindowPolicy.ownership(of: ranges, sampleRate: rate)
    for (range, owned) in zip(ranges, ownership) {
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
      let decoded: TranscriptionResult
      do {
        decoded = try await whisperKit.transcribeFileWindow(
          samples: samples, language: request.language, model: request.model,
          promptTerms: request.hints.terms(for: .whisperKit))
      } catch TranscriptionError.emptyTranscript {
        guard BoundedDecodeWindowPolicy.containsAudibleActivity(samples) else { continue }
        throw TranscriptionError.underlying(
          "Audible recording audio was not transcribed. The recording is saved and will retry.")
      }
      if file.length <= AVAudioFramePosition(windowFrames) { return decoded }
      try assembler.append(decoded, offsetSeconds: Double(start) / rate, ownership: owned,
                           requiresTimings: true)
    }
    return try assembler.finish(language: request.language, duration: Double(file.length) / rate)
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
