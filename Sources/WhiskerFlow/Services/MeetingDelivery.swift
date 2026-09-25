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
    let store = self.store
    let (manifest, hash) = try await Self.offMain {
      (try store.loadManifest(sessionID: sessionID), try store.sourceManifestChecksum(sessionID: sessionID))
    }
    var receipt: RecordingDeliveryReceipt
    if let bytes = try store.readDeliveryReceipt(sessionID: sessionID),
       let saved = try? JSONDecoder().decode(RecordingDeliveryReceipt.self, from: bytes),
       saved.sourceManifestHash == hash,
       saved.meetingID == manifest.atlasMeetingID,
       saved.artifactID == manifest.atlasArtifactID {
      receipt = saved
    } else {
      receipt = try await uploadRecording(sessionID: sessionID, progress: progress)
    }
    // Playback is a convenience copy. Its failure must not hold back local
    // transcription; the transcript is checkpointed and playback resumes.
    var playbackFailure: Error?
    if !receipt.isPlaybackComplete {
      do {
        receipt = try await uploadPlayback(sessionID: sessionID, receipt: receipt)
      } catch {
        if Task.isCancelled || error is CancellationError { throw error }
        playbackFailure = error
      }
    }
    progress("Recording saved in Atlas. Preparing the transcript on this Mac…")
      let result: MeetingLocalProcessingResult
      if let checkpoint = try? store.readProcessingCheckpoint(sessionID: sessionID),
         let saved = try? JSONDecoder().decode(MeetingLocalProcessingResult.self, from: checkpoint) {
        result = saved
      } else {
        // A resumable partial or unreadable checkpoint is not a transcript.
        // The durable source audio can always be processed again.
        result = try await process()
        try store.writeProcessingCheckpoint(sessionID: sessionID, data: JSONEncoder().encode(result))
      }
      if let playbackFailure { throw playbackFailure }
      progress("Sending transcript to Atlas…")
      // No detected speech is a terminal, checkpointed outcome: finalize it so
      // a silent recording is not re-transcribed on every retry.
      if !result.turns.isEmpty {
        if receipt.segmentsKeyedByArtifact == true {
          try await client.appendSegments(meetingID: receipt.meetingID, artifactID: receipt.artifactID, turns: result.turns)
        } else {
          // Earlier builds may already have appended some batches under the
          // meeting-scoped keys; keep them so Atlas idempotency still applies.
          try await client.appendSegments(meetingID: receipt.meetingID, turns: result.turns)
        }
      }
      try await client.finalize(meetingID: receipt.meetingID, artifactID: receipt.artifactID, transcriptionState: "completed", status: "done")
      return MeetingAtlasRecordingCompletion(status: receipt.status, duplicate: false)
  }

  /// Chunk reads, SHA-256 and manifest rewrites scale with meeting length.
  /// Keep them off the main actor so long meetings never stall the UI.
  private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility) { try work() }.value
  }

  private func writeReceipt(_ receipt: RecordingDeliveryReceipt, sessionID: UUID) async throws {
    let store = self.store
    let data = try JSONEncoder().encode(receipt)
    try await Self.offMain { try store.writeDeliveryReceipt(sessionID: sessionID, data: data) }
  }

  /// Uploads the plaintext mixed track for Atlas playback, resuming after the
  /// last durably acknowledged chunk instead of restarting at sequence 0.
  private func uploadPlayback(sessionID: UUID, receipt: RecordingDeliveryReceipt) async throws -> RecordingDeliveryReceipt {
    let store = self.store
    let manifest = try await Self.offMain { try store.loadManifest(sessionID: sessionID) }
    let mixedDescriptors = manifest.chunks
      .filter { $0.track == .mixed }
      .sorted { $0.sequence < $1.sequence }
    var receipt = receipt
    let resumedFrom = min(max(0, receipt.playbackUploadedCount ?? 0), mixedDescriptors.count)
    var uploaded = resumedFrom
    for descriptor in mixedDescriptors.dropFirst(resumedFrom) {
      try Task.checkCancellation()
      let playbackBody = try await Self.offMain { try store.readChunk(sessionID: sessionID, descriptor: descriptor) }
      try await client.uploadPlaybackChunk(
        artifactID: receipt.artifactID,
        descriptor: descriptor,
        body: playbackBody
      )
      uploaded += 1
      if uploaded.isMultiple(of: 10) {
        receipt.playbackUploadedCount = uploaded
        try await writeReceipt(receipt, sessionID: sessionID)
      }
    }
    receipt.playbackUploadedCount = uploaded
    if !mixedDescriptors.isEmpty {
      do {
        try await client.completePlayback(artifactID: receipt.artifactID)
      } catch {
        // If Atlas still lacks chunks after a resumed upload, it may have
        // discarded the earlier ones: upload all of them on the next retry.
        receipt.playbackUploadedCount = resumedFrom > 0 ? 0 : uploaded
        try? await writeReceipt(receipt, sessionID: sessionID)
        throw error
      }
    }
    receipt.playbackComplete = true
    try await writeReceipt(receipt, sessionID: sessionID)
    return receipt
  }

  private func uploadRecording(sessionID: UUID, progress: (String) -> Void) async throws -> RecordingDeliveryReceipt {
    let store = self.store
    let source = try await Self.offMain { try store.loadManifest(sessionID: sessionID) }
    guard !source.chunks.isEmpty else { throw MeetingChunkStoreError.invalidSession }
    let durationMs = source.chunks.map(\.endMs).max() ?? source.durationMs ?? 0
    let sourceGapDetected = source.hasStructuralSourceGap || MeetingAudioTrack.allCases.contains { track in !source.chunks.contains { $0.track == track } }
    let modelVersion: String? = WhisperKitEngine.meetingModelIdentifier
    progress("Sending recording to Atlas…")
      var manifest = source
      let sourceManifestHash = try await Self.offMain { try store.sourceManifestChecksum(sessionID: sessionID) }
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
        let body = try await Self.offMain { try store.readEncryptedChunk(sessionID: sessionID, descriptor: descriptor) }
        try await client.uploadChunk(artifactID: artifactID, descriptor: descriptor, body: body)
        try await Self.offMain {
          try store.markUploaded(sessionID: sessionID, track: descriptor.track, sequence: descriptor.sequence)
        }
      }
      let uploaded = try await Self.offMain { try store.loadManifest(sessionID: sessionID) }
      let counts = Dictionary(
        uniqueKeysWithValues: MeetingAudioTrack.allCases.map { track in
          (track, uploaded.chunks.filter { $0.track == track }.count)
        })
      let missing = MeetingAudioTrack.allCases.filter { counts[$0, default: 0] == 0 }
      let canonicalDescriptors = uploaded.chunks
        .filter { $0.track == .mixed }
        .sorted { $0.sequence < $1.sequence }
      let canonicalChecksum = try await Self.offMain {
        var canonicalHasher = SHA256()
        for descriptor in canonicalDescriptors {
          canonicalHasher.update(
            data: try store.readEncryptedChunk(sessionID: sessionID, descriptor: descriptor))
        }
        return canonicalHasher.finalize().map { String(format: "%02x", $0) }.joined()
      }
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
      // Record audio completion before playback so a playback failure never
      // replays completeRecording or re-uploads acknowledged chunks.
      let receipt = RecordingDeliveryReceipt(
        meetingID: meetingID, artifactID: artifactID, sourceManifestHash: sourceManifestHash,
        status: completion.status, playbackUploadedCount: 0, playbackComplete: false,
        segmentsKeyedByArtifact: true)
      try await writeReceipt(receipt, sessionID: sessionID)
      return receipt
  }
}

private struct RecordingDeliveryReceipt: Codable, Sendable {
  let meetingID: String
  let artifactID: String
  let sourceManifestHash: String
  let status: String
  /// Absent in receipts from earlier builds, which were written only after
  /// playback completed.
  var playbackUploadedCount: Int?
  var playbackComplete: Bool?
  /// Absent in receipts from earlier builds, whose segment batches used
  /// meeting-scoped idempotency keys.
  var segmentsKeyedByArtifact: Bool?

  var isPlaybackComplete: Bool { playbackComplete ?? true }
}
