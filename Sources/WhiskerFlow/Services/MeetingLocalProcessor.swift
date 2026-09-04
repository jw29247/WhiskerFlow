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
  private let transcription: TranscriptionService

  init(transcription: TranscriptionService) {
    self.transcription = transcription
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
    guard
      let mixedURL = try writeTemporaryWAV(
        track: canonicalTrack,
        manifest: manifest,
        store: store,
        directory: processingDirectory
      )
    else {
      throw TranscriptionError.emptyTranscript
    }
    let microphoneURL = try writeTemporaryWAV(
      track: .microphone,
      manifest: manifest,
      store: store,
      directory: processingDirectory
    )
    let systemReader = MeetingSystemAudioWindowReader(manifest: manifest, store: store)

    let canonical = try await transcription.transcribeMeeting(
      audioURL: mixedURL, language: language)
    let selfTranscript: TranscriptionResult?
    if let microphoneURL {
      selfTranscript = try? await transcription.transcribeMeeting(
        audioURL: microphoneURL, language: language)
    } else {
      selfTranscript = nil
    }

    let diarized = await (try? transcription.diarizeMeeting {
      try await systemReader.nextWindow()
    }) ?? []
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

  private func writeTemporaryWAV(
    track: MeetingAudioTrack,
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore,
    directory: URL
  ) throws -> URL? {
    let descriptors = manifest.chunks
      .filter { $0.track == track }
      .sorted { $0.sequence < $1.sequence }
    guard !descriptors.isEmpty else { return nil }
    let url = directory.appendingPathComponent(
      "whiskerflow-meeting-\(manifest.sessionID.uuidString)-\(track.rawValue).wav"
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
    let root = StorageLocations.applicationSupportRootOrTemporary()
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
