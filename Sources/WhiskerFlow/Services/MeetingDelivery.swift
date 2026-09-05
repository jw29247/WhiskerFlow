import CryptoKit
import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Delivers durable audio before loading local models. Transcript retries reuse
/// an encrypted checkpoint so an Atlas outage cannot trigger transcription again.
@MainActor
struct MeetingDelivery {
  let store: EncryptedMeetingChunkStore
  let client: any MeetingAtlasClient

  func deliver(
    sessionID: UUID,
    process: () async throws -> MeetingLocalProcessingResult,
    progress: (String) -> Void
  ) async throws -> MeetingAtlasRecordingCompletion {
    let manifest = try store.loadManifest(sessionID: sessionID)
    let hash = try store.sourceManifestChecksum(sessionID: sessionID)
    let receipt: RecordingDeliveryReceipt
    if let bytes = try store.readDeliveryReceipt(sessionID: sessionID),
       let saved = try? JSONDecoder().decode(RecordingDeliveryReceipt.self, from: bytes),
       saved.sourceManifestHash == hash,
       saved.meetingID == manifest.atlasMeetingID,
       saved.artifactID == manifest.atlasArtifactID {
      receipt = saved
    } else {
      receipt = try await uploadRecording(sessionID: sessionID, progress: progress)
      try store.writeDeliveryReceipt(sessionID: sessionID, data: JSONEncoder().encode(receipt))
    }
    progress("Recording saved in Atlas. Preparing the transcript on this Mac…")
      let result: MeetingLocalProcessingResult
      if let checkpoint = try store.readProcessingCheckpoint(sessionID: sessionID) {
        result = try JSONDecoder().decode(MeetingLocalProcessingResult.self, from: checkpoint)
      } else {
        result = try await process()
        guard !result.turns.isEmpty else { throw TranscriptionError.emptyTranscript }
        try store.writeProcessingCheckpoint(sessionID: sessionID, data: JSONEncoder().encode(result))
      }
      guard !result.turns.isEmpty else { throw TranscriptionError.emptyTranscript }
      progress("Sending transcript to Atlas…")
      try await client.appendSegments(meetingID: receipt.meetingID, turns: result.turns)
      try await client.finalize(meetingID: receipt.meetingID, artifactID: receipt.artifactID, transcriptionState: "completed", status: "done")
      return MeetingAtlasRecordingCompletion(status: receipt.status, duplicate: false)
  }

  private func uploadRecording(sessionID: UUID, progress: (String) -> Void) async throws -> RecordingDeliveryReceipt {
    let source = try store.loadManifest(sessionID: sessionID)
    guard !source.chunks.isEmpty else { throw MeetingChunkStoreError.invalidSession }
    let durationMs = source.chunks.map(\.endMs).max() ?? source.durationMs ?? 0
    let sourceGapDetected = source.hasStructuralSourceGap || MeetingAudioTrack.allCases.contains { track in !source.chunks.contains { $0.track == track } }
    let modelVersion: String? = WhisperKitEngine.meetingModelIdentifier
    progress("Sending recording to Atlas…")
      var manifest = try store.loadManifest(sessionID: sessionID)
      let sourceManifestHash = try store.sourceManifestChecksum(sessionID: sessionID)
      if manifest.atlasMeetingID == nil || manifest.atlasArtifactID == nil {
        let capturedChunkCounts = Dictionary(
          uniqueKeysWithValues: MeetingAudioTrack.allCases.map { track in
            (track, manifest.chunks.filter { $0.track == track }.count)
          }
        )
        let preparedChunkCounts = Dictionary(
          uniqueKeysWithValues: capturedChunkCounts.map { track, count in
            (track, max(1, count))
          }
        )
        let created = try await client.createMeeting(
          captureSessionID: sessionID,
          title: manifest.title ?? "Captured call",
          occurredAtMs: manifest.occurredAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000),
          eventID: manifest.calendarEventID
        )
        let artifactID = try await client.prepareRecording(
          meetingID: created.meetingID,
          captureSessionID: sessionID,
          trackChunkCounts: preparedChunkCounts,
          sourceManifestHash: sourceManifestHash,
          playbackChunkCount: capturedChunkCounts[.mixed] ?? 0
        )
        try store.attachAtlasReferences(
          sessionID: sessionID,
          meetingID: created.meetingID,
          artifactID: artifactID
        )
        manifest = try store.loadManifest(sessionID: sessionID)
      }
      guard let meetingID = manifest.atlasMeetingID, let artifactID = manifest.atlasArtifactID
      else {
        throw MeetingAtlasClientError.invalidResponse
      }
      for descriptor in manifest.pendingChunks {
        try Task.checkCancellation()
        // The authenticated transport receives the exact encrypted bytes
        // described by the source manifest. Plaintext is used only inside the
        // local transcription process.
        let body = try store.readEncryptedChunk(sessionID: sessionID, descriptor: descriptor)
        try await client.uploadChunk(artifactID: artifactID, descriptor: descriptor, body: body)
        try store.markUploaded(
          sessionID: sessionID, track: descriptor.track, sequence: descriptor.sequence)
      }
      let uploaded = try store.loadManifest(sessionID: sessionID)
      let counts = Dictionary(
        uniqueKeysWithValues: MeetingAudioTrack.allCases.map { track in
          (track, uploaded.chunks.filter { $0.track == track }.count)
        })
      let missing = MeetingAudioTrack.allCases.filter { counts[$0, default: 0] == 0 }
      var canonicalHasher = SHA256()
      for descriptor in uploaded.chunks
        .filter({ $0.track == .mixed })
        .sorted(by: { $0.sequence < $1.sequence }) {
        canonicalHasher.update(
          data: try store.readEncryptedChunk(sessionID: sessionID, descriptor: descriptor))
      }
      let canonicalChecksum = canonicalHasher.finalize().map { String(format: "%02x", $0) }.joined()
      let completion = try await client.completeRecording(
        artifactID: artifactID,
        durationMs: durationMs,
        trackChunkCounts: counts,
        hasSourceGap: sourceGapDetected,
        missingTracks: missing,
        canonicalChecksum: canonicalChecksum,
        sourceManifestHash: sourceManifestHash,
        modelVersion: modelVersion
      )
      let mixedDescriptors = uploaded.chunks
        .filter { $0.track == .mixed }
        .sorted { $0.sequence < $1.sequence }
      for descriptor in mixedDescriptors {
        try Task.checkCancellation()
        let playbackBody = try store.readChunk(sessionID: sessionID, descriptor: descriptor)
        try await client.uploadPlaybackChunk(
          artifactID: artifactID,
          descriptor: descriptor,
          body: playbackBody
        )
      }
      if !mixedDescriptors.isEmpty {
        try await client.completePlayback(artifactID: artifactID)
      }

      return RecordingDeliveryReceipt(meetingID: meetingID, artifactID: artifactID, sourceManifestHash: sourceManifestHash, status: completion.status)
  }
}

private struct RecordingDeliveryReceipt: Codable {
  let meetingID: String
  let artifactID: String
  let sourceManifestHash: String
  let status: String
}
