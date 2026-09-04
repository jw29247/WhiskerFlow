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
    case .uncovered: return "No meeting scheduled"
    }
  }
}

@MainActor
@Observable
final class MeetingCaptureCoordinator {
  private static let schedulePollSeconds: UInt64 = 60
  private static let scheduleWindowMs: Int64 = 7 * 24 * 60 * 60 * 1_000
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
  private let clientProvider: (() -> (any MeetingAtlasClient)?)?
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
  private var captureTransitionInProgress = false
  private var heartbeatTask: Task<Void, Never>?
  private var lastFailureCode: String?
  private var didStart = false

  private(set) var status: MeetingMenuBarStatus = .uncovered
  private(set) var statusDetail = "Pair a healthy Mac with Atlas to cover meetings."
  private(set) var lastAtlasMeetingID: String?
  private(set) var activeMeetingTitle: String?
  private(set) var scheduleIntents: [AtlasCaptureScheduleIntent] = []

  var upcomingMeetingIntents: [AtlasCaptureScheduleIntent] {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    return scheduleIntents
      .filter { $0.endMs >= now }
      .sorted { $0.startMs < $1.startMs }
  }

  var previousMeetingIntents: [AtlasCaptureScheduleIntent] {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    return scheduleIntents
      .filter { $0.endMs < now }
      .sorted { $0.startMs > $1.startMs }
  }

  init(
    settings: AppSettings, microphonePermission: MicrophonePermissionController,
    transcription: TranscriptionService,
    store: EncryptedMeetingChunkStore? = nil,
    clientProvider: (() -> (any MeetingAtlasClient)?)? = nil
  ) {
    self.settings = settings
    self.microphonePermission = microphonePermission
    self.transcription = transcription
    self.clientProvider = clientProvider
    let root = StorageLocations.applicationSupportRootOrTemporary()
      .appendingPathComponent("MeetingRecordings", isDirectory: true)
    self.store = store ?? EncryptedMeetingChunkStore(
      rootURL: root,
      keyProvider: KeychainMeetingChunkKeyProvider()
    )
  }

  var isBusy: Bool {
    captureTransitionInProgress || activeSessionID != nil || uploadTask != nil || retryTask != nil || !deliveringSessions.isEmpty
  }

  var isCapturing: Bool { activeSessionID != nil }
  var isCaptureTransitioning: Bool { captureTransitionInProgress }

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
    guard !captureTransitionInProgress else { return }
    if activeSessionID != nil {
      Task { @MainActor [weak self] in await self?.stopCapture(reason: "manual") }
    } else {
      Task { @MainActor [weak self] in await self?.startCapture(intent: nil) }
    }
  }

  func startScheduledCapture(_ intent: AtlasCaptureScheduleIntent) {
    guard activeSessionID == nil, !captureTransitionInProgress else { return }
    Task { @MainActor [weak self] in await self?.startCapture(intent: intent) }
  }

  func refreshSchedule() {
    Task { @MainActor [weak self] in await self?.pollSchedule() }
  }

  func retryPendingRecordings() {
    guard uploadTask == nil, deliveringSessions.isEmpty else { return }
    recoveryTask = Task { @MainActor [weak self] in await self?.recoverLocalSessions() }
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

  func pollSchedule() async {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let intents: [AtlasCaptureScheduleIntent]
    var scheduleFetchFailed = false
    if let client = atlasClient() {
      do {
        let window = MeetingScheduleWindow.automaticCapture(
          nowMs: now,
          lookaheadMs: Self.scheduleWindowMs
        )
        let fresh = try await client.schedule(
          fromMs: window.fromMs,
          toMs: window.toMs
        )
        settings.cacheMeetingSchedule(fresh)
        intents = fresh
      } catch {
        scheduleFetchFailed = true
        lastFailureCode = "schedule"
        intents = cachedSchedule(now: now)
        if !isBusy {
          status = .attention
          statusDetail = intents.isEmpty
            ? "Atlas schedule is temporarily unavailable; local capture remains available manually."
            : "Atlas is offline; using the cached schedule for local capture."
        }
        DiagnosticsService.capture(error: error, category: "network", code: "meeting_schedule")
      }
    } else {
      intents = cachedSchedule(now: now)
      if intents.isEmpty {
        updateUnpairedStatus()
        return
      }
      if !isBusy {
        status = .attention
        statusDetail = "Atlas is offline; scheduled calls will be captured locally and queued."
      }
    }

    scheduleIntents = intents

    // The calendar is useful in manual mode too. Only auto-start is opt-in.
    guard settings.meetingModeEnabled else {
      if !isBusy && !scheduleFetchFailed {
        status = .covered
        statusDetail = "Ready to record. Automatic recording is off."
      }
      return
    }
    let automaticIntents = MeetingCaptureSchedulePolicy.automaticCaptureIntents(from: intents)

    if activeSessionID != nil || captureTransitionInProgress {
      if activeSessionID != nil {
        extendActiveCaptureIfNeeded(automaticIntents)
      }
      return
    }
    guard
      let next = automaticIntents.first(where: {
        $0.startMs - Self.preArmWindowMs <= now && now <= $0.endMs + Self.stopGraceMs
      })
    else {
      if !isBusy && !scheduleFetchFailed && atlasClient() != nil {
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
      .filter { $0.endMs >= now - Self.scheduleWindowMs && $0.startMs <= now + Self.scheduleWindowMs }
      .sorted { $0.startMs < $1.startMs }
  }

  /// Keep one physical recording alive when another calendar event begins
  /// before the current capture's scheduled stop. The extra event is surfaced
  /// as a conflict, but never receives a second independent artifact from the
  /// same Mac audio stream.
  private func extendActiveCaptureIfNeeded(_ intents: [AtlasCaptureScheduleIntent]) {
    guard let activeIntent,
          activeIntent.isEligibleForAutomaticCapture,
          let currentStop = activeCaptureStopAtMs else { return }
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
      self?.stopTask = nil
      await self?.stopCapture(reason: "scheduled_end")
    }
  }

  private func startCapture(intent: AtlasCaptureScheduleIntent?) async {
    guard Self.isSupportedMac else {
      status = .uncovered
      statusDetail = "Meeting Mode requires an Apple Silicon Mac."
      return
    }
    guard activeSessionID == nil, !captureTransitionInProgress else { return }
    captureTransitionInProgress = true
    defer { captureTransitionInProgress = false }
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
      statusDetail = error.localizedDescription
      DiagnosticsService.capture(error: error, category: "audio", code: "meeting_start")
    }
  }

  private func stopCapture(reason: String) async {
    guard let sessionID = activeSessionID,
          let capture = audioCapture,
          !captureTransitionInProgress else { return }
    captureTransitionInProgress = true
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
      // Release the capture transition only after the stream has stopped. A
      // schedule poll can now start a genuinely separate meeting while the
      // finished session is transcribed/uploaded below.
      captureTransitionInProgress = false
      let manifest = try store.loadManifest(sessionID: sessionID)
      let durationMs = manifest.chunks.map(\.endMs).max() ?? 0
      let sourceGapDetected = capture.sourceGapDetected
      try store.markState(
        sessionID: sessionID,
        state: .awaitingTranscription,
        durationMs: durationMs,
        sourceGapDetected: sourceGapDetected
      )
      await deliver(sessionID: sessionID)
    } catch {
      captureTransitionInProgress = false
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

  private var deliveringSessions: Set<UUID> = []

  func deliver(sessionID: UUID) async {
    guard !deliveringSessions.contains(sessionID) else { return }
    deliveringSessions.insert(sessionID)
    defer { deliveringSessions.remove(sessionID) }
    guard let client = atlasClient() else {
      if canPublishStatus(for: sessionID) {
        status = .attention
        statusDetail = "Recording is saved on this Mac. Connect Atlas to send it."
      }
      scheduleUploadRetry()
      return
    }
    do {
      let delivery = MeetingDelivery(store: store, client: client)
      let completion = try await delivery.deliver(sessionID: sessionID) {
        try self.store.markState(sessionID: sessionID, state: .awaitingTranscription)
        let processor = MeetingLocalProcessor(transcription: self.transcription)
        self.localProcessor = processor
        return try await processor.process(manifest: self.store.loadManifest(sessionID: sessionID), store: self.store, language: self.settings.resolvedLanguage)
      } progress: { detail in
        if self.canPublishStatus(for: sessionID) {
          self.status = .uploading
          self.statusDetail = detail
        }
      }
      if canPublishStatus(for: sessionID) {
        let covered = completion.status == "recorded_pending_transcription" || completion.status == "covered"
        status = covered ? .covered : .attention
        statusDetail = !covered
          ? "Sent to Atlas. Some audio was missing; the recording is marked partial."
          : "Recording and transcript saved in Atlas. Meeting notes are being prepared."
        lastFailureCode = nil
      }
      lastAtlasMeetingID = try store.loadManifest(sessionID: sessionID).atlasMeetingID
      try store.removeSession(sessionID: sessionID)
    } catch {
      try? store.markState(sessionID: sessionID, state: .failed)
      if canPublishStatus(for: sessionID) {
        lastFailureCode = "meeting_delivery"
        status = .attention
        statusDetail = "Meeting saved locally. \(error.localizedDescription) Will retry automatically."
      }
      DiagnosticsService.capture(error: error, category: "network", code: "meeting_delivery")
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
          let pending = try self.store.recoverSessions().filter { $0.state != .recording && !$0.chunks.isEmpty }
          guard !pending.isEmpty else { return }
          await self.retryPendingSessions(pending)
          let stillPending = try self.store.recoverSessions().contains { $0.state != .recording && !$0.chunks.isEmpty }
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
    guard uploadTask == nil else { return }
    do {
      let sessions = MeetingRecordingSessionManifest.orderedForRecovery(
        try store.recoverSessions())
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
      // Empty abandoned starts contain no recoverable audio. Keep them on disk,
      // but do not make them block or continually restart the recovery queue.
      guard !session.chunks.isEmpty else { continue }
      guard session.sessionID != activeSessionID else { continue }
      await deliver(sessionID: session.sessionID)
    }
    uploadTask = nil
  }

  private static var forecastChunkCounts: [MeetingAudioTrack: Int] {
    Dictionary(uniqueKeysWithValues: MeetingAudioTrack.allCases.map { ($0, forecastChunkCount) })
  }

  private func atlasClient() -> MeetingAtlasClient? {
    if let clientProvider { return clientProvider() }
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
    guard !isBusy else { return }
    guard Self.isSupportedMac else {
      status = .uncovered
      statusDetail = "Meeting Mode requires an Apple Silicon Mac."
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
