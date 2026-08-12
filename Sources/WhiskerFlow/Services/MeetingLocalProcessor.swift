import AVFoundation
import Foundation
import SpeakerKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct MeetingLocalProcessingResult: Sendable {
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
    let mixed = try samples(for: .mixed, manifest: manifest, store: store)
    let microphone = try samples(for: .microphone, manifest: manifest, store: store)
    let system = try samples(for: .system, manifest: manifest, store: store)
    guard !mixed.isEmpty else { throw TranscriptionError.emptyTranscript }

    let mixedURL = try writeTemporaryWAV(samples: mixed)
    let microphoneURL = microphone.isEmpty ? nil : try writeTemporaryWAV(samples: microphone)
    defer {
      try? FileManager.default.removeItem(at: mixedURL)
      if let microphoneURL { try? FileManager.default.removeItem(at: microphoneURL) }
    }

    let canonical = try await transcription.transcribeMeeting(
      audioURL: mixedURL, language: language)
    let selfTranscript: TranscriptionResult?
    if let microphoneURL {
      selfTranscript = try? await transcription.transcribeMeeting(
        audioURL: microphoneURL, language: language)
    } else {
      selfTranscript = nil
    }

    let diarized = await diarize(system.isEmpty ? mixed : system)
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

    let durationMs = Int64(((canonical.duration ?? Double(mixed.count) / 16_000) * 1_000).rounded())
    return MeetingLocalProcessingResult(
      turns: turns,
      modelVersion: WhisperKitEngine.meetingModelIdentifier,
      durationMs: durationMs
    )
  }

  private func samples(
    for track: MeetingAudioTrack,
    manifest: MeetingRecordingSessionManifest,
    store: EncryptedMeetingChunkStore
  ) throws -> [Float] {
    let descriptors = manifest.chunks
      .filter { $0.track == track }
      .sorted { $0.sequence < $1.sequence }
    return try descriptors.flatMap { descriptor in
      let data = try store.readChunk(sessionID: manifest.sessionID, descriptor: descriptor)
      return data.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Float.self))
      }
    }
  }

  private func writeTemporaryWAV(samples: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("whiskerflow-meeting-\(UUID().uuidString).wav")
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
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(samples.count)
      ), let channel = buffer.floatChannelData?[0]
    else {
      throw TranscriptionError.underlying("Meeting audio buffer could not be created")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      channel.update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
    return url
  }

  private func matchesSelf(_ segment: TranscriptionSegment, in selfSegments: [TranscriptionSegment])
    -> Bool {
    selfSegments.contains { candidate in
      let overlap = max(0, min(segment.end, candidate.end) - max(segment.start, candidate.start))
      let duration = max(0.01, segment.end - segment.start)
      let normalizedSegment = normalize(segment.text)
      let normalizedCandidate = normalize(candidate.text)
      return overlap / duration >= 0.55
        && (normalizedSegment == normalizedCandidate
          || normalizedSegment.contains(normalizedCandidate)
          || normalizedCandidate.contains(normalizedSegment))
    }
  }

  private func diarize(_ samples: [Float]) async -> [SpeakerSegment] {
    guard !samples.isEmpty else { return [] }
    // Audio is retained locally and the caller will upload a safe
    // `Unknown speaker` transcript if the shared diarizer cannot load/run.
    return await (try? transcription.diarizeMeeting(samples: samples)) ?? []
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
