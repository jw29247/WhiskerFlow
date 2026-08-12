import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum MeetingMenuBarStatus: String, Sendable {
  case covered
  case recording
  case uploading
  case attention
  case uncovered

  var displayName: String {
    switch self {
    case .covered: return "Covered"
    case .recording: return "Recording"
    case .uploading: return "Uploading"
    case .attention: return "Attention"
    case .uncovered: return "Uncovered"
    }
  }
}

@MainActor
@Observable
final class MeetingCaptureCoordinator {
  private static let schedulePollSeconds: UInt64 = 60
  private static let preArmWindowMs: Int64 = 2 * 60 * 1_000
  private static let stopGraceMs: Int64 = 5 * 60 * 1_000
  private static let forecastChunkCount = 720  // two hours at ten seconds/chunk
  #if arch(arm64)
    private static let isSupportedMac = true
  #else
    private static let isSupportedMac = false
  #endif

  private let settings: AppSettings
  private let microphonePermission: MicrophonePermissionController
  private let keychain = MeetingCaptureTokenStore()
  private let transcription: TranscriptionService
  private let store: EncryptedMeetingChunkStore
  private var scheduleTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var uploadTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var activeIntent: AtlasCaptureScheduleIntent?
  private var activeSessionID: UUID?
  private var audioCapture: MeetingAudioCaptureService?
  private var localProcessor: MeetingLocalProcessor?
  private var stopTask: Task<Void, Never>?
  private var activeCaptureStopAtMs: Int64?
  private var activeOverlapDetected = false
  private var heartbeatTask: Task<Void, Never>?
  private var lastFailureCode: String?
  private var didStart = false

  private(set) var status: MeetingMenuBarStatus = .uncovered
  private(set) var statusDetail = "Pair a healthy Mac with Atlas to cover meetings."
  private(set) var activeMeetingTitle: String?

  init(
    settings: AppSettings, microphonePermission: MicrophonePermissionController,
    transcription: TranscriptionService
  ) {
    self.settings = settings
    self.microphonePermission = microphonePermission
    self.transcription = transcription
    let root = StorageLocations.applicationSupportRootOrTemporary()
      .appendingPathComponent("MeetingRecordings", isDirectory: true)
    self.store = EncryptedMeetingChunkStore(
      rootURL: root,
      keyProvider: KeychainMeetingChunkKeyProvider()
    )
  }

  var isBusy: Bool {
    activeSessionID != nil || uploadTask != nil || retryTask != nil
  }

  var isCapturing: Bool { activeSessionID != nil }

  func start() {
    guard !didStart else { return }
    didStart = true
    recoveryTask = Task { @MainActor [weak self] in
      await self?.recoverLocalSessions()
    }
    heartbeatTask = Task { @MainActor [weak self] in
      await self?.heartbeatLoop()
    }
    scheduleTask = Task { @MainActor [weak self] in
      await self?.scheduleLoop()
    }
    updateUnpairedStatus()
  }

  func stopMonitoring() {
    scheduleTask?.cancel()
    scheduleTask = nil
    recoveryTask?.cancel()
    recoveryTask = nil
    retryTask?.cancel()
    retryTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  func shutdown() async {
    stopMonitoring()
    stopTask?.cancel()
    if activeSessionID != nil {
      let drain = Task { @MainActor [weak self] () in
        guard let self else { return }
        await self.stopCapture(reason: "shutdown")
      }
      let completed = await waitForShutdownTask(drain, timeout: 3)
      if !completed { drain.cancel() }
    }
    uploadTask?.cancel()
    retryTask?.cancel()
  }

  func toggleManualCapture() {
    if activeSessionID != nil {
      Task { @MainActor [weak self] in await self?.stopCapture(reason: "manual") }
    } else {
      Task { @MainActor [weak self] in await self?.startCapture(intent: nil) }
    }
  }

  func refreshConfiguration() {
    updateUnpairedStatus()
  }

  private func scheduleLoop() async {
    while !Task.isCancelled {
      await pollSchedule()
      try? await Task.sleep(nanoseconds: Self.schedulePollSeconds * 1_000_000_000)
    }
  }

  private func pollSchedule() async {
    guard settings.meetingModeEnabled else {
      status = .uncovered
      statusDetail = "Scheduled Meeting Mode is disabled in Settings."
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let intents: [AtlasCaptureScheduleIntent]
    if let client = atlasClient() {
      do {
        let fresh = try await client.schedule(
          fromMs: now - Self.preArmWindowMs,
          toMs: now + 24 * 60 * 60 * 1_000
        )
        settings.cacheMeetingSchedule(fresh)
        intents = fresh
      } catch {
        intents = cachedSchedule(now: now)
        status = .attention
        statusDetail =
          intents.isEmpty
          ? "Atlas schedule is temporarily unavailable; local capture remains available manually."
          : "Atlas is offline; using the cached schedule for local capture."
      }
    } else {
      intents = cachedSchedule(now: now)
      if intents.isEmpty {
        updateUnpairedStatus()
        return
      }
      status = .attention
      statusDetail = "Atlas is offline; scheduled calls will be captured locally and queued."
    }

    if activeSessionID != nil {
      extendActiveCaptureIfNeeded(intents)
      return
    }
    guard
      let next = intents.first(where: {
        $0.startMs - Self.preArmWindowMs <= now && now <= $0.endMs + Self.stopGraceMs
      })
    else {
      if atlasClient() != nil {
        status = .covered
        statusDetail = "Ready for the next scheduled meeting."
      }
      return
    }
    if next.overlapsPrevious {
      status = .attention
      statusDetail = "Overlapping calendar meetings need one shared capture session."
    }
    await startCapture(intent: next)
  }

  private func cachedSchedule(now: Int64) -> [AtlasCaptureScheduleIntent] {
    settings.cachedMeetingSchedule()
      .filter { $0.endMs + Self.stopGraceMs >= now }
      .sorted { $0.startMs < $1.startMs }
  }

  /// Keep one physical recording alive when another calendar event begins
  /// before the current capture's scheduled stop. The extra event is surfaced
  /// as a conflict, but never receives a second independent artifact from the
  /// same Mac audio stream.
  private func extendActiveCaptureIfNeeded(_ intents: [AtlasCaptureScheduleIntent]) {
    guard let activeIntent, let currentStop = activeCaptureStopAtMs else { return }
    let captureStart = activeIntent.startMs - Self.preArmWindowMs
    let extensionStop = intents
      .filter {
        $0.eventID != activeIntent.eventID
          && $0.startMs - Self.preArmWindowMs <= currentStop
          && $0.endMs > captureStart
      }
      .map { $0.endMs + Self.stopGraceMs }
      .max()
    guard let extensionStop, extensionStop > currentStop else { return }
    activeOverlapDetected = true
    status = .attention
    statusDetail = "Overlapping meetings share one physical audio capture."
    scheduleCaptureStop(atMs: extensionStop)
  }

  private func scheduleCaptureStop(atMs: Int64) {
    stopTask?.cancel()
    activeCaptureStopAtMs = atMs
    let delay = max(0, atMs - Int64(Date().timeIntervalSince1970 * 1_000))
    stopTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
      guard !Task.isCancelled else { return }
      await self?.stopCapture(reason: "scheduled_end")
    }
  }

  private func startCapture(intent: AtlasCaptureScheduleIntent?) async {
    guard Self.isSupportedMac else {
      status = .uncovered
      statusDetail = "Meeting Mode requires an Apple Silicon Mac."
      return
    }
    guard activeSessionID == nil else { return }
    guard localDiskState() == "ready" else {
      status = .uncovered
      statusDetail = "At least 500 MB of local storage is required before recording."
      return
    }
    guard CGPreflightScreenCaptureAccess() else {
      status = .uncovered
      statusDetail = "Screen Recording permission is required for Mac system audio."
      return
    }
    let authorization = await microphonePermission.requestIfNeeded()
    guard authorization == .authorized else {
      status = .uncovered
      statusDetail = "Microphone permission is required for Meeting Mode."
      return
    }

    let sessionID = UUID()
    do {
      _ = try store.beginSession(
        sessionID: sessionID,
        meetingID: nil,
        expectedChunkCounts: [
          .microphone: Self.forecastChunkCount,
          .system: Self.forecastChunkCount,
          .mixed: Self.forecastChunkCount,
        ],
        title: intent?.title ?? "Ad hoc meeting",
        calendarEventID: intent?.eventID,
        occurredAtMs: intent?.startMs ?? Int64(Date().timeIntervalSince1970 * 1_000)
      )
      let capture = MeetingAudioCaptureService(store: store, sessionID: sessionID)
      capture.onFailure = { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self, self.canPublishStatus(for: sessionID) else { return }
          self.lastFailureCode = "capture_stream"
          self.status = .attention
          self.statusDetail =
            "Audio capture needs attention; the written local chunks are retained."
          DiagnosticsService.capture(error: error, category: "audio", code: "meeting_capture")
        }
      }
      try await capture.start(selection: settings.selectedInput)
      self.audioCapture = capture
      self.activeSessionID = sessionID
      self.activeIntent = intent
      self.activeOverlapDetected = intent?.overlapsPrevious ?? false
      self.activeMeetingTitle = intent?.title ?? "Ad hoc meeting"
      lastFailureCode = nil
      if activeOverlapDetected {
        status = .attention
        statusDetail = "Overlapping meetings share one physical audio capture."
      } else {
        status = .recording
        statusDetail = intent == nil ? "Recording ad hoc meeting." : "Recording scheduled meeting."
      }

      if let endMs = intent?.endMs {
        scheduleCaptureStop(atMs: endMs + Self.stopGraceMs)
      } else {
        activeCaptureStopAtMs = nil
      }
    } catch {
      lastFailureCode = "capture_start"
      // A microphone callback can write a chunk before Screen Recording
      // authorization or stream startup fails. Keep every written chunk
      // encrypted and recoverable instead of deleting evidence of a
      // partial/uncovered meeting.
      try? store.markState(sessionID: sessionID, state: .failed)
      if let manifest = try? store.loadManifest(sessionID: sessionID), !manifest.chunks.isEmpty {
        scheduleUploadRetry()
      }
      status = .uncovered
      statusDetail =
        "Meeting Mode could not start; check Microphone and Screen Recording permissions."
      DiagnosticsService.capture(error: error, category: "audio", code: "meeting_start")
    }
  }

  private func stopCapture(reason: String) async {
    guard let sessionID = activeSessionID, let capture = audioCapture else { return }
    stopTask?.cancel()
    stopTask = nil
    activeCaptureStopAtMs = nil
    activeOverlapDetected = false
    activeSessionID = nil
    audioCapture = nil
    activeIntent = nil
    status = .uploading
    statusDetail = "Finishing local recording and transcription."

    do {
      _ = try await capture.stop()
      let manifest = try store.loadManifest(sessionID: sessionID)
      let durationMs = manifest.chunks.map(\.endMs).max() ?? 0
      let sourceGapDetected = capture.sourceGapDetected
      try store.markState(
        sessionID: sessionID,
        state: .awaitingTranscription,
        durationMs: durationMs,
        sourceGapDetected: sourceGapDetected
      )
      let processor = MeetingLocalProcessor(transcription: transcription)
      localProcessor = processor
      let result = try await processor.process(
        manifest: try store.loadManifest(sessionID: sessionID),
        store: store,
        language: settings.resolvedLanguage
      )
      try store.markState(sessionID: sessionID, state: .completed, durationMs: result.durationMs)
      await upload(
        sessionID: sessionID,
        turns: result.turns,
        durationMs: result.durationMs,
        sourceGapDetected: sourceGapDetected,
        modelVersion: result.modelVersion,
        reason: reason
      )
    } catch {
      lastFailureCode = "local_processing"
      if canPublishStatus(for: sessionID) {
        status = .attention
        statusDetail = "Audio is retained locally for repair after processing failed."
      }
      try? store.markState(sessionID: sessionID, state: .failed)
      scheduleUploadRetry()
      DiagnosticsService.capture(error: error, category: "storage", code: "meeting_process")
    }
  }

  private func upload(
    sessionID: UUID,
    turns: [MeetingSpeakerTurn],
    durationMs: Int64,
    sourceGapDetected: Bool,
    modelVersion: String?,
    reason: String
  ) async {
    _ = reason
    guard let client = atlasClient() else {
      status = .attention
      statusDetail = "Recording and transcript are retained locally until Atlas is paired."
      scheduleUploadRetry()
      return
    }
    do {
      try Task.checkCancellation()
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
      try await client.appendSegments(meetingID: meetingID, turns: turns)
      try await client.finalize(
        meetingID: meetingID,
        artifactID: artifactID,
        transcriptionState: "completed",
        status: "done"
      )
      if canPublishStatus(for: sessionID) {
        if completion.status == "recorded_pending_transcription" || completion.status == "covered" {
          status = .covered
          statusDetail = "Recording, checksums, and speaker-labelled transcript verified in Atlas."
        } else {
          status = .attention
          statusDetail = "Recording uploaded with a source gap; Atlas marked it partial."
        }
        lastFailureCode = nil
      }
      try? store.removeSession(sessionID: sessionID)
    } catch {
      if canPublishStatus(for: sessionID) {
        lastFailureCode = "upload"
        status = .uploading
        statusDetail = "Recording is safe locally; upload will retry when Atlas is reachable."
      }
      scheduleUploadRetry()
    }
  }

  private func scheduleUploadRetry() {
    guard retryTask == nil else { return }
    retryTask = Task { @MainActor [weak self] in
      defer { self?.retryTask = nil }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        guard !Task.isCancelled, let self else { return }
        do {
          let pending = try self.store.recoverSessions().filter { $0.state != .recording }
          guard !pending.isEmpty else { return }
          await self.retryPendingSessions(pending)
          let stillPending = try self.store.recoverSessions().contains { $0.state != .recording }
          if !stillPending { return }
        } catch {
          if self.activeSessionID == nil {
            self.status = .attention
            self.statusDetail =
              "Pending local recordings need attention; encrypted audio was retained."
          }
          DiagnosticsService.capture(error: error, category: "storage", code: "meeting_retry")
        }
      }
    }
  }

  private func recoverLocalSessions() async {
    do {
      let sessions = try store.recoverSessions()
      let pending = sessions
      if !pending.isEmpty {
        uploadTask = Task { @MainActor [weak self] in
          await self?.retryPendingSessions(pending)
        }
      }
    } catch {
      if activeSessionID == nil {
        status = .attention
        statusDetail = "Pending local recordings need attention."
      }
    }
  }

  private func retryPendingSessions(_ sessions: [MeetingRecordingSessionManifest]) async {
    for session in sessions {
      guard !Task.isCancelled else { return }
      do {
        if canPublishStatus(for: session.sessionID) {
          status = .uploading
          statusDetail = "Repairing a previous local recording."
        }
        let manifest = try store.loadManifest(sessionID: session.sessionID)
        // A session still marked as recording means the process ended
        // before it could close the final chunk set. Preserve every
        // written chunk, but keep the coverage claim honest until a
        // user or later repair can establish that no source gap exists.
        let recoveredSourceGap = manifest.sourceGapDetected || manifest.state == .recording
        let processor = MeetingLocalProcessor(transcription: transcription)
        localProcessor = processor
        try store.markState(
          sessionID: session.sessionID,
          state: .awaitingTranscription,
          durationMs: manifest.durationMs,
          sourceGapDetected: recoveredSourceGap
        )
        let result = try await processor.process(
          manifest: try store.loadManifest(sessionID: session.sessionID),
          store: store,
          language: settings.resolvedLanguage
        )
        try store.markState(
          sessionID: session.sessionID, state: .completed, durationMs: result.durationMs)
        await upload(
          sessionID: session.sessionID,
          turns: result.turns,
          durationMs: result.durationMs,
          sourceGapDetected: recoveredSourceGap,
          modelVersion: result.modelVersion,
          reason: "recovery"
        )
      } catch {
        try? store.markState(sessionID: session.sessionID, state: .failed)
        if canPublishStatus(for: session.sessionID) {
          status = .attention
          statusDetail = "A previous local recording needs repair; encrypted audio was retained."
        }
        scheduleUploadRetry()
        DiagnosticsService.capture(error: error, category: "storage", code: "meeting_recovery")
      }
    }
    uploadTask = nil
  }

  private static var forecastChunkCounts: [MeetingAudioTrack: Int] {
    Dictionary(uniqueKeysWithValues: MeetingAudioTrack.allCases.map { ($0, forecastChunkCount) })
  }

  private func atlasClient() -> MeetingAtlasClient? {
    guard let baseURL = URL(string: settings.atlasBaseURL),
      baseURL.scheme == "https",
      let token = keychain.read(),
      !token.isEmpty
    else { return nil }
    return URLSessionMeetingAtlasClient(baseURL: baseURL, token: token)
  }

  private func heartbeatLoop() async {
    while !Task.isCancelled {
      await sendHeartbeat()
      try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
    }
  }

  private func sendHeartbeat() async {
    guard let client = atlasClient() else { return }
    let permissionState = [
      "microphone": microphonePermission.isGranted ? "granted" : "denied",
      "screenRecording": CGPreflightScreenCaptureAccess() ? "granted" : "denied",
    ]
    let captureState: String
    switch status {
    case .recording: captureState = "recording"
    case .uploading: captureState = "uploading"
    case .attention: captureState = "attention"
    case .uncovered: captureState = "uncovered"
    case .covered: captureState = "idle"
    }
    let diskState = localDiskState()
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    try? await client.heartbeat(
      appVersion: appVersion,
      permissionState: permissionState,
      diskState: diskState,
      captureState: captureState,
      lastFailureReason: lastFailureCode
    )
  }

  private func localDiskState() -> String {
    let root = StorageLocations.applicationSupportRootOrTemporary()
      .appendingPathComponent("MeetingRecordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard
      let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]
      ),
      let capacity = values.volumeAvailableCapacityForImportantUsage
    else { return "unknown" }
    if capacity < 100 * 1024 * 1024 { return "full" }
    if capacity < 500 * 1024 * 1024 { return "low" }
    return "ready"
  }

  private func updateUnpairedStatus() {
    guard Self.isSupportedMac else {
      status = .uncovered
      statusDetail = "Meeting Mode requires an Apple Silicon Mac."
      return
    }
    guard settings.meetingModeEnabled else {
      status = .uncovered
      statusDetail = "Scheduled Meeting Mode is disabled in Settings."
      return
    }
    guard atlasClient() != nil else {
      status = .uncovered
      statusDetail = "Pair this Mac with Atlas and grant Microphone + Screen Recording permissions."
      return
    }
    guard CGPreflightScreenCaptureAccess() else {
      status = .uncovered
      statusDetail = "Screen Recording permission is required for Mac system audio."
      return
    }
    guard microphonePermission.isGranted else {
      status = .uncovered
      statusDetail = "Microphone permission is required for Meeting Mode."
      return
    }
    guard localDiskState() == "ready" else {
      status = .uncovered
      statusDetail = "At least 500 MB of local storage is required before recording."
      return
    }
    if activeSessionID == nil {
      status = .covered
      statusDetail = "Ready for the next scheduled meeting."
    }
  }

  private func canPublishStatus(for sessionID: UUID) -> Bool {
    activeSessionID == nil || activeSessionID == sessionID
  }

  private func waitForShutdownTask(
    _ task: Task<Void, Never>,
    timeout: UInt64
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      let gate = MeetingShutdownGate(continuation)
      Task {
        await task.value
        gate.resolve(true)
      }
      Task {
        try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
        gate.resolve(false)
      }
    }
  }
}

private final class MeetingShutdownGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resolved = false
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func resolve(_ value: Bool) {
    lock.lock()
    guard !resolved, let continuation else {
      lock.unlock()
      return
    }
    resolved = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(returning: value)
  }
}
