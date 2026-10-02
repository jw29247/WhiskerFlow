import AVFoundation
import CryptoKit
import Foundation
import Logging
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct MeetingWindowTranscriptionFailure: LocalizedError {
  let track: MeetingAudioTrack
  let startMs: Int64
  let endMs: Int64
  var errorDescription: String? { "Audible meeting audio was not transcribed. The recording is saved and will retry." }
}

struct MeetingLocalProcessingResult: Codable, Sendable {
  let turns: [MeetingSpeakerTurn]
  let modelVersion: String
  let durationMs: Int64
  /// Audible canonical windows that every bounded retry decoded as empty
  /// (hold music, typing, coughs). Retained as gaps rather than failing.
  var untranscribedAudibleWindowCount: Int? = nil
}

/// Resumable per-window progress, stored in the encrypted processing
/// checkpoint. It never decodes as a `MeetingLocalProcessingResult`.
struct MeetingLocalProcessingProgress: Codable, Sendable {
  struct Segment: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
  }
  struct Track: Codable, Sendable {
    var completedWindows = 0
    var segments: [Segment] = []
    var language: String?
    var duration: Double = 0
    var audibleWindows = 0
    var untranscribedWindows: [[Int64]] = []
    /// Set when most audible windows decoded empty during this app launch.
    var majorityEmptyLaunchID: UUID?
  }
  static let currentVersion = 1
  var progressVersion = currentVersion
  let sourceKey: String
  var tracks: [String: Track] = [:]
}

/// Post-meeting-only local processing. The canonical text comes from Parakeet
/// over the mixed track; microphone transcription is used only as an explicit
/// timing/text alignment signal for the `You` label. Everyone else is "Them",
/// or their name where Google Meet's tiles showed who was speaking. Splitting
/// the other voices apart (diarization) was dropped: a 1:1 huddle came back as
/// five speakers, and two-hour calls as 34. No audio leaves this process.
actor MeetingLocalProcessor {
  private static let audibleChunkRetryCount = 3
  private static let audibleChunkSubwindowCount = 2
  private static let transientDecodeAttemptCount = 3
  /// Mean square of the RMS 0.015 audibility floor used for source windows.
  private static let audibleMeanSquare = 0.015 * 0.015
  /// About +3 dB: mic energy must clearly exceed the remote audio it overlaps.
  private static let selfDominanceRatio = 2.0
  /// Identifies this process, so a majority-empty verdict is re-decoded only
  /// after a relaunch (fresh decoder state or an updated build).
  private static let launchID = UUID()

  typealias MeetingTranscriber = @Sendable (URL, String?) async throws -> TranscriptionResult

  private let transcribeMeeting: MeetingTranscriber
  private let processingRoot: URL?
  private let transientRetryUnitNanoseconds: UInt64

  init(transcription: TranscriptionService, processingRoot: URL? = nil) {
    self.transcribeMeeting = { url, language in
      try await transcription.transcribeMeeting(audioURL: url, language: language)
    }
    self.processingRoot = processingRoot
    self.transientRetryUnitNanoseconds = 1_000_000_000
  }

  init(
    processingRoot: URL,
    transcribeMeeting: @escaping MeetingTranscriber,
    transientRetryUnitNanoseconds: UInt64 = 1_000_000_000
  ) {
    self.transcribeMeeting = transcribeMeeting
    self.processingRoot = processingRoot
    self.transientRetryUnitNanoseconds = transientRetryUnitNanoseconds
  }

  /// - Parameter resumable: persist per-window progress in the session's
  ///   encrypted checkpoint so cancellation or a transient failure resumes
  ///   at the next window instead of re-decoding the whole meeting.
  func process(
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    language: String?,
    resumable: Bool = true
  ) async throws -> MeetingLocalProcessingResult {
    let processingDirectory = try makeProcessingDirectory(sessionID: manifest.sessionID)
    defer { try? FileManager.default.removeItem(at: processingDirectory) }
    let canonicalTrack: MeetingAudioTrack = manifest.chunks.contains { $0.track == .mixed }
      ? .mixed : (manifest.chunks.contains { $0.track == .system } ? .system : .microphone)
    var checkpoint = resumable
      ? Self.loadProgress(manifest: manifest, store: store, language: language)
      : MeetingLocalProcessingProgress(sourceKey: "")
    guard let canonical = try await transcribeTrack(
      track: canonicalTrack,
      manifest: manifest,
      store: store,
      directory: processingDirectory,
      language: language,
      alignmentOnly: false,
      checkpoint: &checkpoint,
      persist: resumable
    ) else {
      throw TranscriptionError.emptyTranscript
    }
    let selfTranscript: TranscriptionResult?
    do {
      // Alignment-only: an undecodable microphone window is skipped so the
      // rest of the `You` evidence survives.
      selfTranscript = try await transcribeTrack(
        track: .microphone,
        manifest: manifest,
        store: store,
        directory: processingDirectory,
        language: language,
        alignmentOnly: true,
        checkpoint: &checkpoint,
        persist: resumable
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      selfTranscript = nil
    }
    try Task.checkCancellation()
    let speakerEvidence = (try? store.loadSpeakerEvidence(sessionID: manifest.sessionID)) ?? []
    // The microphone is captured without echo cancellation: on speakers it
    // also hears remote participants. Loaded only if a fuzzy match needs it.
    var energy: (microphone: MeetingTrackEnergyProfile, system: MeetingTrackEnergyProfile)??
    let turns = canonical.segments.map { segment in
      let startMs = Int64((segment.start * 1_000).rounded())
      let endMs = Int64((max(segment.end, segment.start) * 1_000).rounded())
      let identity: MeetingSpeakerIdentity
      if matchesSelf(segment, in: selfTranscript?.segments ?? [], microphoneDominates: {
        if energy == nil {
          energy = .some(try? (MeetingTrackEnergyProfile(track: .microphone, manifest: manifest, store: store),
                               MeetingTrackEnergyProfile(track: .system, manifest: manifest, store: store)))
        }
        // Unreadable energy fails closed to "Them".
        guard let profiles = energy ?? nil else { return false }
        return Self.microphoneDominates(segment, microphone: profiles.microphone, system: profiles.system)
      }) {
        identity = .microphone
      } else if !(selfTranscript?.segments ?? []).contains(where: { $0.end > segment.start && $0.start < segment.end }),
                let named = MeetingSpeakerEvidenceMatcher.identity(startMs: startMs, endMs: endMs, evidence: speakerEvidence) {
        identity = named
      } else {
        identity = .others
      }
      return MeetingSpeakerTurn(
        startMs: startMs,
        endMs: endMs,
        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
        speaker: identity
      )
    }.filter { !$0.text.isEmpty }

    let fallbackDuration = Double(manifest.chunks.map(\.endMs).max() ?? 0) / 1_000
    let durationMs = manifest.chunks.map(\.endMs).max() ?? Int64(fallbackDuration * 1_000)
    let untranscribed = checkpoint.tracks[canonicalTrack.rawValue]?.untranscribedWindows.count ?? 0
    return MeetingLocalProcessingResult(
      turns: turns,
      modelVersion: TranscriptionService.meetingModelIdentifier,
      durationMs: durationMs,
      untranscribedAudibleWindowCount: untranscribed > 0 ? untranscribed : nil
    )
  }

  private func windowFailure(sessionID: UUID, track: MeetingAudioTrack, startMs: Int64, endMs: Int64) -> MeetingWindowTranscriptionFailure {
    Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing").warning(
      "Meeting window decode failed",
      metadata: ["event": "meeting_window_empty", "session": .string(sessionID.uuidString),
                 "track": .string(track.rawValue), "window_start_ms": .string(String(startMs)),
                 "window_end_ms": .string(String(endMs)), "outcome": "failed"]
    )
    return MeetingWindowTranscriptionFailure(track: track, startMs: startMs, endMs: endMs)
  }

  private func logUntranscribedWindow(sessionID: UUID, track: MeetingAudioTrack, startMs: Int64, endMs: Int64) {
    Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing").warning(
      "Audible meeting window retained as an untranscribed gap",
      metadata: ["event": "meeting_window_empty", "session": .string(sessionID.uuidString),
                 "track": .string(track.rawValue), "window_start_ms": .string(String(startMs)),
                 "window_end_ms": .string(String(endMs)), "reason": "empty"]
    )
  }

  private func logAlignmentStopped(sessionID: UUID, startMs: Int64, error: Error) {
    Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing").warning(
      "Microphone alignment pass stopped; decoded self evidence retained",
      metadata: ["event": "meeting_alignment_stopped", "session": .string(sessionID.uuidString),
                 "track": .string(MeetingAudioTrack.microphone.rawValue), "window_start_ms": .string(String(startMs)),
                 "reason": .string(String(describing: type(of: error)))]
    )
  }

  /// Binds progress to the exact source chunks, model and language so a
  /// changed manifest or setting never resumes from stale windows.
  private static func progressKey(manifest: MeetingRecordingSessionManifest, language: String?) -> String {
    var lines = ["session=\(manifest.sessionID.uuidString)", "model=\(TranscriptionService.meetingModelIdentifier)",
                 "language=\(language ?? "auto")", "window=\(MeetingTranscriptionWindowPolicy.maximumDurationMs)"]
    for chunk in manifest.chunks.sorted(by: { ($0.track.rawValue, $0.sequence) < ($1.track.rawValue, $1.sequence) }) {
      lines.append("\(chunk.track.rawValue)|\(chunk.sequence)|\(chunk.startMs)|\(chunk.endMs)|\(chunk.checksum)")
    }
    return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func loadProgress(
    manifest: MeetingRecordingSessionManifest, store: EncryptedMeetingChunkStore, language: String?
  ) -> MeetingLocalProcessingProgress {
    let key = progressKey(manifest: manifest, language: language)
    if let data = try? store.readProcessingCheckpoint(sessionID: manifest.sessionID),
       let saved = try? JSONDecoder().decode(MeetingLocalProcessingProgress.self, from: data),
       saved.progressVersion == MeetingLocalProcessingProgress.currentVersion, saved.sourceKey == key {
      return saved
    }
    return MeetingLocalProcessingProgress(sourceKey: key)
  }

  private static func saveProgress(
    _ progress: MeetingLocalProcessingProgress, sessionID: UUID, store: EncryptedMeetingChunkStore
  ) {
    // Best effort: a failed write only costs re-decoding on the next attempt.
    guard let data = try? JSONEncoder().encode(progress) else { return }
    try? store.writeProcessingCheckpoint(sessionID: sessionID, data: data)
  }

  /// Retries decoder errors that are usually transient on slower Macs: a
  /// deadline under thermal pressure, or the model gate still held by an
  /// abandoned decode or a dictation. Waits scale with the failure kind.
  private func decodeWithTransientRetry(_ url: URL, _ language: String?) async throws -> TranscriptionResult {
    var attempt = 0
    while true {
      do {
        return try await transcribeMeeting(url, language)
      } catch let error as TranscriptionError {
        let delayUnits: UInt64
        switch error {
        case .timedOut: delayUnits = 10
        case .underlying: delayUnits = UInt64(5 * (attempt + 1))
        default: throw error
        }
        attempt += 1
        guard attempt < Self.transientDecodeAttemptCount else { throw error }
        try await Task.sleep(nanoseconds: delayUnits * transientRetryUnitNanoseconds)
      }
    }
  }

  private func transcribeTrack(
    track: MeetingAudioTrack,
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL,
    language: String?,
    alignmentOnly: Bool,
    checkpoint: inout MeetingLocalProcessingProgress,
    persist: Bool
  ) async throws -> TranscriptionResult? {
    let descriptors = manifest.chunks
      .filter { $0.track == track }
      .sorted { $0.sequence < $1.sequence }
    guard !descriptors.isEmpty else { return nil }
    var progress = checkpoint.tracks[track.rawValue] ?? MeetingLocalProcessingProgress.Track()
    // Empty decodes of the same audio repeat, so a majority-empty verdict from
    // this launch fails fast; a later launch re-decodes the track once.
    if !alignmentOnly, let verdictLaunch = progress.majorityEmptyLaunchID {
      if verdictLaunch == Self.launchID, let failure = progress.untranscribedWindows.first {
        throw windowFailure(sessionID: manifest.sessionID, track: track, startMs: failure[0], endMs: failure[1])
      }
      progress = MeetingLocalProcessingProgress.Track()
    }
    var segments = progress.segments.map { TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
    var resolvedLanguage = progress.language
    var duration = progress.duration
    let windows = MeetingTranscriptionWindowPolicy.windows(descriptors)
    windowLoop: for (index, window) in windows.enumerated() {
      // Windows already recorded in the checkpoint are not decoded again.
      guard index >= progress.completedWindows else { continue }
      try Task.checkCancellation()
      guard let first = window.first, let last = window.last else { continue }
      let materialized = try writeTemporaryWAV(
        descriptors: window,
        manifest: manifest,
        store: store,
        directory: directory,
        name: "\(track.rawValue)-\(index)"
      )
      defer { try? FileManager.default.removeItem(at: materialized.url) }
      if materialized.containsAudibleActivity { progress.audibleWindows += 1 }
      var decodedResult: TranscriptionResult?
      do {
        decodedResult = try await decodeWithTransientRetry(materialized.url, language)
      } catch TranscriptionError.emptyTranscript {
        // A decoder can emit an empty result for a longer window even when the
        // same source decodes at smaller boundaries. Retry each durable chunk
        // and bounded subwindows before treating the window as non-speech.
        if materialized.containsAudibleActivity {
          let recovery: (result: TranscriptionResult?, firstAudibleFailure: (startMs: Int64, endMs: Int64)?)
          do {
            recovery = try await recoverEmptyWindow(
              window, track: track, index: index, manifest: manifest, store: store,
              directory: directory, language: language)
          } catch let error where alignmentOnly && !(error is CancellationError) && !Task.isCancelled {
            logAlignmentStopped(sessionID: manifest.sessionID, startMs: first.startMs, error: error)
            break windowLoop
          }
          decodedResult = recovery.result
          if decodedResult == nil {
            let failure = recovery.firstAudibleFailure ?? (first.startMs, last.endMs)
            logUntranscribedWindow(sessionID: manifest.sessionID, track: track, startMs: failure.startMs, endMs: failure.endMs)
            progress.untranscribedWindows.append([failure.startMs, failure.endMs])
          }
        }
      } catch let error where alignmentOnly && !(error is CancellationError) && !Task.isCancelled {
        // A deadline or held model gate after bounded retries means the decoder
        // is unavailable, so later windows would fail too. Keep the `You`
        // evidence decoded so far; this window stays pending for a later run.
        logAlignmentStopped(sessionID: manifest.sessionID, startMs: first.startMs, error: error)
        break windowLoop
      }
      if let result = decodedResult {
        let offset = Double(first.startMs) / 1_000
        let ownershipBoundary = index > 0 && window.count > 1
          ? Double(window[1].startMs) / 1_000
          : nil
        for segment in result.segments {
          let rebased = TranscriptionSegment(
            text: segment.text,
            start: segment.start + offset,
            end: segment.end + offset
          )
          MeetingSegmentReconciler.insert(
            rebased,
            ownershipBoundary: ownershipBoundary,
            into: &segments
          )
        }
        resolvedLanguage = resolvedLanguage ?? result.language
        duration = max(duration, Double(last.endMs) / 1_000)
      }
      progress.completedWindows = index + 1
      progress.segments = segments.map { .init(text: $0.text, start: $0.start, end: $0.end) }
      progress.language = resolvedLanguage
      progress.duration = duration
      checkpoint.tracks[track.rawValue] = progress
      if persist { Self.saveProgress(checkpoint, sessionID: manifest.sessionID, store: store) }
      // Stop early once the verdict below is certain for the whole track.
      if !alignmentOnly, progress.untranscribedWindows.count * 2 > windows.count { break }
    }
    // Non-speech noise in a few windows is a gap. When most audible canonical
    // audio decodes empty, the decoder may be at fault rather than the audio:
    // keep the recording and fail. Decoded windows stay checkpointed, so retries
    // in this launch fail fast instead of re-decoding the meeting.
    if !alignmentOnly, let failure = progress.untranscribedWindows.first,
       progress.untranscribedWindows.count * 2 > progress.audibleWindows {
      progress.majorityEmptyLaunchID = Self.launchID
      checkpoint.tracks[track.rawValue] = progress
      if persist { Self.saveProgress(checkpoint, sessionID: manifest.sessionID, store: store) }
      throw windowFailure(sessionID: manifest.sessionID, track: track, startMs: failure[0], endMs: failure[1])
    }
    segments.sort { ($0.start, $0.end) < ($1.start, $1.end) }
    let text = segments.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // No speech anywhere is a valid, terminal outcome (for example an
    // unattended or silent recording); callers decide how to deliver it.
    return TranscriptionResult(
      text: text.plainTranscriptText,
      segments: segments,
      language: resolvedLanguage ?? language,
      duration: duration
    )
  }

  /// Bounded recovery for an audible window that decoded empty: each durable
  /// chunk is retried, then split into subwindows. Returns nil when every
  /// attempt is still empty.
  private func recoverEmptyWindow(
    _ window: [MeetingRecordingChunkDescriptor],
    track: MeetingAudioTrack,
    index: Int,
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL,
    language: String?
  ) async throws -> (result: TranscriptionResult?, firstAudibleFailure: (startMs: Int64, endMs: Int64)?) {
    guard let first = window.first else { return (nil, nil) }
    var recovered: [TranscriptionSegment] = []
    var firstAudibleFailure: (startMs: Int64, endMs: Int64)?
    for descriptor in window {
      try Task.checkCancellation()
      let retry = try writeTemporaryWAV(descriptors: [descriptor], manifest: manifest, store: store,
                                        directory: directory, name: "\(track.rawValue)-\(index)-retry-\(descriptor.sequence)")
      defer { try? FileManager.default.removeItem(at: retry.url) }
      var decoded: TranscriptionResult?
      // A single-chunk window was just decoded whole; go straight to subwindows.
      let chunkAttempts = window.count > 1 ? Self.audibleChunkRetryCount : 0
      for attempt in 0..<chunkAttempts {
        do {
          decoded = try await decodeWithTransientRetry(retry.url, language)
          break
        } catch TranscriptionError.emptyTranscript {
          guard retry.containsAudibleActivity else { break }
          guard attempt + 1 < Self.audibleChunkRetryCount else { break }
          // A short retry gives the model time to release a transient
          // decoder/VAD failure without allowing overlapping model work.
          try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 200_000_000)
        }
      }
      if decoded == nil, retry.containsAudibleActivity {
        let source = try readSamples(
          descriptors: [descriptor], manifest: manifest, store: store
        )
        let partSize = max(1, source.count / Self.audibleChunkSubwindowCount)
        var subwindowFailed = false
        for part in 0..<Self.audibleChunkSubwindowCount {
          let start = part * partSize
          let end = part == Self.audibleChunkSubwindowCount - 1
            ? source.count : min(source.count, start + partSize)
          guard start < end else { continue }
          let subwindow = try writeTemporaryWAV(
            samples: source[start..<end], directory: directory,
            name: "\(track.rawValue)-\(index)-subretry-\(descriptor.sequence)-\(part)"
          )
          defer { try? FileManager.default.removeItem(at: subwindow.url) }
          guard subwindow.containsAudibleActivity else { continue }
          for attempt in 0..<Self.audibleChunkRetryCount {
            do {
              decoded = try await decodeWithTransientRetry(subwindow.url, language)
              break
            } catch TranscriptionError.emptyTranscript {
              guard attempt + 1 < Self.audibleChunkRetryCount else { break }
              try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 200_000_000)
            }
          }
          if let subwindowDecoded = decoded {
            let offset = Double(descriptor.startMs - first.startMs) / 1_000
              + Double(start) / 16_000
            recovered.append(contentsOf: subwindowDecoded.segments.map {
              TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            })
            decoded = nil
          } else {
            subwindowFailed = true
          }
        }
        if subwindowFailed {
          firstAudibleFailure = firstAudibleFailure ?? (descriptor.startMs, descriptor.endMs)
        }
      }
      if let decoded {
        let offset = Double(descriptor.startMs - first.startMs) / 1000
        recovered.append(contentsOf: decoded.segments.map {
          TranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        })
      }
    }
    guard !recovered.isEmpty else { return (nil, firstAudibleFailure) }
    return (TranscriptionResult(text: recovered.map(\.text).joined(separator: " "), segments: recovered, language: language),
            firstAudibleFailure)
  }

  private func writeTemporaryWAV(
    descriptors: [MeetingRecordingChunkDescriptor],
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL,
    name: String
  ) throws -> MaterializedMeetingWindow {
    let url = directory.appendingPathComponent(
      "whiskerflow-meeting-\(manifest.sessionID.uuidString)-\(name).wav"
    )
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var containsAudibleActivity = false
    for descriptor in descriptors {
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      guard data.count % MemoryLayout<Float>.size == 0 else {
        throw TranscriptionError.underlying("Meeting audio chunk is not aligned")
      }
      let sampleCount = data.count / MemoryLayout<Float>.size
      if !containsAudibleActivity {
        containsAudibleActivity = data.withUnsafeBytes { rawBuffer in
          Self.containsAudibleActivity(Array(rawBuffer.bindMemory(to: Float.self)))
        }
      }
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: AVAudioFrameCount(sampleCount)
        ), let channel = buffer.floatChannelData?[0]
      else {
        throw TranscriptionError.underlying("Meeting audio buffer could not be created")
      }
      buffer.frameLength = AVAudioFrameCount(sampleCount)
      data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        channel.update(
          from: baseAddress.assumingMemoryBound(to: Float.self),
          count: sampleCount
        )
      }
      try file.write(from: buffer)
    }
    return MaterializedMeetingWindow(
      url: url,
      containsAudibleActivity: containsAudibleActivity
    )
  }

  private func readSamples(
    descriptors: [MeetingRecordingChunkDescriptor],
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore
  ) throws -> [Float] {
    try descriptors.flatMap { descriptor in
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      guard data.count % MemoryLayout<Float>.size == 0 else {
        throw TranscriptionError.underlying("Meeting audio chunk is not aligned")
      }
      return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
  }

  private func writeTemporaryWAV(
    samples: ArraySlice<Float>, directory: URL, name: String
  ) throws -> MaterializedMeetingWindow {
    let url = directory.appendingPathComponent(
      "whiskerflow-meeting-\(name).wav"
    )
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let values = Array(samples)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(values.count)),
      let channel = buffer.floatChannelData?[0]
    else {
      throw TranscriptionError.underlying("Meeting audio buffer could not be created")
    }
    buffer.frameLength = AVAudioFrameCount(values.count)
    values.withUnsafeBufferPointer { pointer in
      guard let baseAddress = pointer.baseAddress else { return }
      channel.update(from: baseAddress, count: values.count)
    }
    try file.write(from: buffer)
    return MaterializedMeetingWindow(url: url, containsAudibleActivity: Self.containsAudibleActivity(values))
  }

  private static func containsAudibleActivity(_ samples: [Float]) -> Bool {
    let blockSize = 16_000
    for start in stride(from: 0, to: samples.count, by: blockSize) {
      let end = min(samples.count, start + blockSize)
      let block = samples[start..<end]
      guard !block.isEmpty else { continue }
      let meanSquare = block.reduce(0.0) { $0 + Double($1 * $1) } / Double(block.count)
      if meanSquare.squareRoot() >= 0.015 { return true }
    }
    return false
  }

  private func makeProcessingDirectory(sessionID: UUID) throws -> URL {
    let root = processingRoot ?? StorageLocations.applicationSupportRootOrTemporary()
      .appendingPathComponent("MeetingProcessing", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let staleCutoff = Date().addingTimeInterval(-60 * 60)
    let staleEntries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for entry in staleEntries {
      if entry.pathExtension == "wav" {
        try? fileManager.removeItem(at: entry)
        continue
      }
      let modifiedAt = try? entry.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate
      if entry.lastPathComponent != sessionID.uuidString,
         modifiedAt ?? .distantPast < staleCutoff {
        try? fileManager.removeItem(at: entry)
      }
    }
    let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
  }

  /// Independent mic and mixed decodes rarely agree on segment boundaries or
  /// exact wording (punctuation, a remote backchannel). An exact, sustained
  /// match is accepted as before. A looser match (overlap plus most canonical
  /// words on the mic) also needs the mic to dominate the system track there,
  /// because remote speech played on speakers is transcribed on the mic too.
  func matchesSelf(
    _ segment: TranscriptionSegment,
    in selfSegments: [TranscriptionSegment],
    microphoneDominates: () -> Bool = { true }
  ) -> Bool {
    let words = normalize(segment.text).split(separator: " ").map(String.init)
    guard !words.isEmpty else { return false }
    let duration = max(0.01, segment.end - segment.start)
    let overlapping = selfSegments.filter { $0.end > segment.start && $0.start < segment.end }
    let normalizedSegment = words.joined(separator: " ")
    if overlapping.contains(where: { candidate in
      let overlap = max(0, min(segment.end, candidate.end) - max(segment.start, candidate.start))
      return overlap / duration >= 0.75 && normalize(candidate.text) == normalizedSegment
    }) {
      return true
    }
    let overlap = overlapping.reduce(0.0) {
      $0 + max(0, min(segment.end, $1.end) - max(segment.start, $1.start))
    }
    guard min(1, overlap / duration) >= 0.5 else { return false }
    var available = overlapping.flatMap { normalize($0.text).split(separator: " ").map(String.init) }
      .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    var matched = 0
    for word in words where available[word, default: 0] > 0 {
      available[word, default: 0] -= 1
      matched += 1
    }
    return Double(matched) / Double(words.count) >= 0.6 && microphoneDominates()
  }

  /// The user's own voice reaches the mic far louder than the system track
  /// carries it (normally not at all); speaker echo is quieter on the mic
  /// than the remote audio itself. A quiet system track cannot be echoed.
  static func microphoneDominates(
    _ segment: TranscriptionSegment,
    microphone: MeetingTrackEnergyProfile,
    system: MeetingTrackEnergyProfile
  ) -> Bool {
    guard let systemEnergy = system.meanSquare(start: segment.start, end: segment.end),
          systemEnergy >= Self.audibleMeanSquare else { return true }
    let microphoneEnergy = microphone.meanSquare(start: segment.start, end: segment.end) ?? 0
    return microphoneEnergy >= Self.selfDominanceRatio * systemEnergy
  }

  private func normalize(_ value: String) -> String {
    value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }
}

private struct MaterializedMeetingWindow {
  let url: URL
  let containsAudibleActivity: Bool
}

/// Mean-square energy of one track in 100 ms blocks on the meeting timeline.
/// Bounded memory (about 290 KB for a two-hour meeting) and one chunk read.
struct MeetingTrackEnergyProfile {
  static let blockMs: Int64 = 100
  private static let samplesPerBlock = Int(16_000 * blockMs / 1_000)
  private var blocks: [Float] = []
  private var covered: [Bool] = []

  init(track: MeetingAudioTrack, manifest: MeetingRecordingSessionManifest, store: EncryptedMeetingChunkStore) throws {
    for descriptor in manifest.chunks where descriptor.track == track {
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      guard data.count % MemoryLayout<Float>.size == 0 else {
        throw TranscriptionError.underlying("Meeting audio chunk is not aligned")
      }
      let firstBlock = Int(max(0, descriptor.startMs) / Self.blockMs)
      data.withUnsafeBytes { rawBuffer in
        let samples = rawBuffer.bindMemory(to: Float.self)
        for (offset, start) in stride(from: 0, to: samples.count, by: Self.samplesPerBlock).enumerated() {
          let end = min(samples.count, start + Self.samplesPerBlock)
          var sum: Float = 0
          for index in start..<end { sum += samples[index] * samples[index] }
          let block = firstBlock + offset
          if block >= blocks.count {
            blocks.append(contentsOf: repeatElement(0, count: block - blocks.count + 1))
            covered.append(contentsOf: repeatElement(false, count: block - covered.count + 1))
          }
          blocks[block] = sum / Float(end - start)
          covered[block] = true
        }
      }
    }
  }

  /// Nil when the track has no audio in the span.
  func meanSquare(start: Double, end: Double) -> Double? {
    let first = max(0, Int((start * 1_000) / Double(Self.blockMs)))
    let last = min(blocks.count - 1, Int((max(end, start) * 1_000) / Double(Self.blockMs)))
    guard first <= last else { return nil }
    let values = (first...last).filter { covered[$0] }.map { Double(blocks[$0]) }
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
}

enum MeetingSegmentReconciler {
  static func insert(
    _ incoming: TranscriptionSegment,
    ownershipBoundary: Double?,
    into segments: inout [TranscriptionSegment]
  ) {
    let incomingText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !incomingText.isEmpty else { return }
    guard let boundary = ownershipBoundary, incoming.start < boundary else {
      segments.append(incoming)
      return
    }

    // Only the repeated acoustic context may be reconciled. Speech whose
    // timestamp begins in the new window is always retained, including a
    // deliberate repetition of the same words.
    let candidateIndices = segments.indices.filter {
      segments[$0].end > incoming.start && segments[$0].start < boundary
    }
    let existingOriginal = candidateIndices.flatMap { tokens(segments[$0].text).original }
    let existingNormalized = candidateIndices.flatMap { tokens(segments[$0].text).normalized }
    let incomingTokens = tokens(incomingText)
    guard !existingNormalized.isEmpty, !incomingTokens.normalized.isEmpty else {
      segments.append(incoming)
      return
    }

    // A later decode may group several earlier segments into one, or split one
    // earlier segment into several. If its words are already a contiguous part
    // of the owned overlap, retain the earlier timing and segment boundaries.
    if contains(existingNormalized, incomingTokens.normalized) { return }

    let overlap = tokenOverlap(existingNormalized, incomingTokens.normalized)
    guard overlap > 0 else {
      segments.append(incoming)
      return
    }
    let mergedTokens = existingOriginal + incomingTokens.original.dropFirst(overlap)
    let merged = TranscriptionSegment(
      text: mergedTokens.joined(separator: " "),
      start: min(candidateIndices.map { segments[$0].start }.min() ?? incoming.start, incoming.start),
      end: max(candidateIndices.map { segments[$0].end }.max() ?? incoming.end, incoming.end)
    )
    for index in candidateIndices.reversed() { segments.remove(at: index) }
    segments.append(merged)
  }

  private static func tokens(_ text: String) -> (original: [String], normalized: [String]) {
    let original = text.split(whereSeparator: \.isWhitespace).map(String.init)
    let benignEdgePunctuation = CharacterSet(charactersIn: ".,!?;:()[]{}\"")
    let normalized = original.map {
      $0.lowercased().trimmingCharacters(in: benignEdgePunctuation)
    }
    return (original, normalized)
  }

  private static func tokenOverlap(_ left: [String], _ right: [String]) -> Int {
    let limit = min(left.count, right.count)
    for count in stride(from: limit, through: 1, by: -1) {
      if Array(left.suffix(count)) == Array(right.prefix(count)) { return count }
    }
    return 0
  }

  private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return (0...(haystack.count - needle.count)).contains {
      Array(haystack[$0..<($0 + needle.count)]) == needle
    }
  }
}

enum MeetingTranscriptionWindowPolicy {
  // Windows of at most 30 seconds keep each decode short, so dictation never
  // waits long behind a meeting window, and a resumed meeting re-decodes little.
  static let maximumDurationMs: Int64 = 30_000

  static func windows(
    _ descriptors: [MeetingRecordingChunkDescriptor]
  ) -> [[MeetingRecordingChunkDescriptor]] {
    var result: [[MeetingRecordingChunkDescriptor]] = []
    var current: [MeetingRecordingChunkDescriptor] = []
    var windowStartMs: Int64?
    var previous: MeetingRecordingChunkDescriptor?
    for descriptor in descriptors {
      let exceedsDuration = windowStartMs.map {
        descriptor.endMs - $0 > maximumDurationMs
      } ?? false
      let followsGap = previous.map {
          descriptor.sequence != $0.sequence + 1 || descriptor.startMs > $0.endMs
        } ?? false
      let mustSplit = exceedsDuration || followsGap
      if mustSplit, !current.isEmpty {
        result.append(current)
        // Re-read one source chunk as acoustic context so a word crossing the
        // boundary is present in at least one decode. Timestamp/text overlap is
        // removed when results are merged.
        current = exceedsDuration && !followsGap ? previous.map { [$0] } ?? [] : []
        windowStartMs = current.first?.startMs
      }
      if windowStartMs == nil { windowStartMs = descriptor.startMs }
      current.append(descriptor)
      previous = descriptor
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}

