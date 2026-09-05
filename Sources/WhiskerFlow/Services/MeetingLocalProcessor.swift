import AVFoundation
import Foundation
import SpeakerKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct MeetingLocalProcessingResult: Codable, Sendable {
  let turns: [MeetingSpeakerTurn]
  let modelVersion: String
  let durationMs: Int64
}

/// Post-meeting-only local processing. The canonical text comes from WhisperKit
/// over the mixed track; microphone transcription is used only as an explicit
/// timing/text alignment signal for the `You` label. SpeakerKit supplies stable
/// diarized labels for the remaining turns. No audio leaves this process.
actor MeetingLocalProcessor {
  typealias MeetingTranscriber = @Sendable (URL, String?) async throws -> TranscriptionResult
  typealias MeetingDiarizer = @Sendable (
    @escaping @Sendable () async throws -> MeetingAudioWindow?
  ) async throws -> [SpeakerSegment]

  private let transcribeMeeting: MeetingTranscriber
  private let diarizeMeeting: MeetingDiarizer
  private let processingRoot: URL?

  init(transcription: TranscriptionService) {
    self.transcribeMeeting = { url, language in
      try await transcription.transcribeMeeting(audioURL: url, language: language)
    }
    self.diarizeMeeting = { nextWindow in
      try await transcription.diarizeMeeting(nextWindow: nextWindow)
    }
    self.processingRoot = nil
  }

  init(
    processingRoot: URL,
    transcribeMeeting: @escaping MeetingTranscriber,
    diarizeMeeting: @escaping MeetingDiarizer = { _ in [] }
  ) {
    self.transcribeMeeting = transcribeMeeting
    self.diarizeMeeting = diarizeMeeting
    self.processingRoot = processingRoot
  }

  func process(
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    language: String?
  ) async throws -> MeetingLocalProcessingResult {
    let processingDirectory = try makeProcessingDirectory(sessionID: manifest.sessionID)
    defer { try? FileManager.default.removeItem(at: processingDirectory) }
    let canonicalTrack: MeetingAudioTrack = manifest.chunks.contains { $0.track == .mixed }
      ? .mixed : (manifest.chunks.contains { $0.track == .system } ? .system : .microphone)
    guard let canonical = try await transcribeTrack(
      track: canonicalTrack,
      manifest: manifest,
      store: store,
      directory: processingDirectory,
      language: language
    ) else {
      throw TranscriptionError.emptyTranscript
    }
    let selfTranscript: TranscriptionResult?
    do {
      selfTranscript = try await transcribeTrack(
        track: .microphone,
        manifest: manifest,
        store: store,
        directory: processingDirectory,
        language: language
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      selfTranscript = nil
    }
    try Task.checkCancellation()
    let systemReader = MeetingSystemAudioWindowReader(manifest: manifest, store: store)

    let diarized = await (try? diarizeMeeting {
      try await systemReader.nextWindow()
    }) ?? []
    try Task.checkCancellation()
    let turns = canonical.segments.map { segment in
      let startMs = Int64((segment.start * 1_000).rounded())
      let endMs = Int64((max(segment.end, segment.start) * 1_000).rounded())
      let identity: MeetingSpeakerIdentity
      if matchesSelf(segment, in: selfTranscript?.segments ?? []) {
        identity = .microphone
      } else if let diarizedSpeaker = diarizedSpeaker(
        start: segment.start,
        end: segment.end,
        segments: diarized
      ) {
        identity = .diarized(key: "speaker-\(diarizedSpeaker + 1)", index: diarizedSpeaker + 1)
      } else {
        identity = .unknown(key: "unknown")
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
    return MeetingLocalProcessingResult(
      turns: turns,
      modelVersion: WhisperKitEngine.meetingModelIdentifier,
      durationMs: durationMs
    )
  }

  private func transcribeTrack(
    track: MeetingAudioTrack,
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL,
    language: String?
  ) async throws -> TranscriptionResult? {
    let descriptors = manifest.chunks
      .filter { $0.track == track }
      .sorted { $0.sequence < $1.sequence }
    guard !descriptors.isEmpty else { return nil }
    var segments: [TranscriptionSegment] = []
    var resolvedLanguage: String?
    var duration: Double = 0
    for (index, window) in MeetingTranscriptionWindowPolicy.windows(descriptors).enumerated() {
      try Task.checkCancellation()
      guard let first = window.first, let last = window.last else { continue }
      let url = try writeTemporaryWAV(
        descriptors: window,
        manifest: manifest,
        store: store,
        directory: directory,
        name: "\(track.rawValue)-\(index)"
      )
      defer { try? FileManager.default.removeItem(at: url) }
      let result: TranscriptionResult
      do {
        result = try await transcribeMeeting(url, language)
      } catch TranscriptionError.emptyTranscript {
        // A silent window is not evidence that the whole meeting is empty.
        continue
      }
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
    segments.sort { ($0.start, $0.end) < ($1.start, $1.end) }
    let text = segments.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
    return TranscriptionResult(
      text: text.plainTranscriptText,
      segments: segments,
      language: resolvedLanguage ?? language,
      duration: duration
    )
  }

  private func writeTemporaryWAV(
    descriptors: [MeetingRecordingChunkDescriptor],
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL,
    name: String
  ) throws -> URL {
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
    for descriptor in descriptors {
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      guard data.count % MemoryLayout<Float>.size == 0 else {
        throw TranscriptionError.underlying("Meeting audio chunk is not aligned")
      }
      let sampleCount = data.count / MemoryLayout<Float>.size
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
    return url
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

  private func matchesSelf(_ segment: TranscriptionSegment, in selfSegments: [TranscriptionSegment])
    -> Bool {
    selfSegments.contains { candidate in
      let overlap = max(0, min(segment.end, candidate.end) - max(segment.start, candidate.start))
      let duration = max(0.01, segment.end - segment.start)
      let normalizedSegment = normalize(segment.text)
      let normalizedCandidate = normalize(candidate.text)
      return overlap / duration >= 0.75 && normalizedSegment == normalizedCandidate
    }
  }

  private func diarizedSpeaker(
    start: Double,
    end: Double,
    segments: [SpeakerSegment]
  ) -> Int? {
    let best = segments.compactMap { segment -> (Int, Double)? in
      guard let speakerID = segment.speaker.speakerId else { return nil }
      let overlap = max(
        0, min(end, Double(segment.endTime)) - max(start, Double(segment.startTime)))
      return overlap > 0 ? (speakerID, overlap) : nil
    }.max { $0.1 < $1.1 }
    return best?.0
  }

  private func normalize(_ value: String) -> String {
    value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
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
  static let maximumDurationMs: Int64 = 60_000

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

private actor MeetingSystemAudioWindowReader {
  private static let sampleRate = 16_000.0
  private static let windowSampleCount = 30 * Int(sampleRate)

  private let manifest: MeetingRecordingSessionManifest
  private let store: EncryptedMeetingChunkStore
  private let descriptors: [MeetingRecordingChunkDescriptor]
  private var descriptorIndex = 0
  private var pendingSamples: [Float] = []
  private var pendingStartMs: Int64?

  init(manifest: MeetingRecordingSessionManifest, store: EncryptedMeetingChunkStore) {
    self.manifest = manifest
    self.store = store
    self.descriptors = manifest.chunks
      .filter { $0.track == .system }
      .sorted { $0.sequence < $1.sequence }
  }

  func nextWindow() throws -> MeetingAudioWindow? {
    while pendingSamples.count < Self.windowSampleCount, descriptorIndex < descriptors.count {
      let descriptor = descriptors[descriptorIndex]
      descriptorIndex += 1
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      guard data.count % MemoryLayout<Float>.size == 0 else {
        throw TranscriptionError.underlying("Meeting audio chunk is not aligned")
      }
      if pendingStartMs == nil { pendingStartMs = descriptor.startMs }
      pendingSamples.append(contentsOf: data.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Float.self))
      })
    }

    guard !pendingSamples.isEmpty, let startMs = pendingStartMs else { return nil }
    let count = min(Self.windowSampleCount, pendingSamples.count)
    let samples = Array(pendingSamples.prefix(count))
    pendingSamples.removeFirst(count)
    if pendingSamples.isEmpty {
      pendingStartMs = nil
    } else {
      pendingStartMs = Int64(
        (Double(startMs) + Double(count) / Self.sampleRate * 1_000).rounded()
      )
    }
    return MeetingAudioWindow(offsetSeconds: Double(startMs) / 1_000, samples: samples)
  }
}
