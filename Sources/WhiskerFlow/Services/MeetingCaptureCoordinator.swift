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
  let assistant = MeetingAssistantController()
  private static let schedulePollSeconds: UInt64 = 60
  private static let scheduleWindowMs: Int64 = 7 * 24 * 60 * 60 * 1_000
  private static let preArmWindowMs: Int64 = 2 * 60 * 1_000
  private static let stopGraceMs: Int64 = 5 * 60 * 1_000
  private static let forecastChunkCount = 720  // two hours at ten seconds/chunk
  /// Stopping ScreenCaptureKit and flushing the final chunks can take several
  /// seconds on a slow Mac. Quitting waits this long for that phase only.
  private static let shutdownCaptureDrainSeconds: UInt64 = 8
  private static let retryPollSeconds: TimeInterval = 60
  private static let microphonePendingDetail =
    "Recording Mac audio. The microphone is not delivering audio yet."
  #if arch(arm64)
    private static let isSupportedMac = true
  #else
    private static let isSupportedMac = false
  #endif

  private let settings: AppSettings
  private let microphonePermission: MicrophonePermissionController
  private let joinedMeetingProvider: (@Sendable (String?) async -> Bool)?
  private let tokenReader: @Sendable () -> String?
  private let diskStateReader: @Sendable () -> String
  private let transcription: TranscriptionService
  private let store: EncryptedMeetingChunkStore
  private let clientProvider: (() -> (any MeetingAtlasClient)?)?
  private var scheduleTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var uploadTask: Task<Void, Never>?
  private var uploadTaskID: UUID?
  private var retryTask: Task<Void, Never>?
  private var retryTaskID: UUID?
  private var retryTaskSleepsForBackoff = false
  private var releaseManualRetryHoldsOnNextScan = false
  private var retryBackoff = MeetingRetryBackoff()
  /// Events the user stopped by hand; the schedule poll must not restart them.
  private var suppressedEvents = MeetingCaptureSuppression()
  /// Stream stop + final chunk flush for the capture being finished. Kept
  /// separate from delivery so shutdown can await it without transcription.
  private var finishingCaptureTask: Task<Void, Error>?
  private var activeIntent: AtlasCaptureScheduleIntent?
  private var activeSessionID: UUID?
  /// The newest capture owns user-visible delivery status even after its audio
  /// stream stops. Older recovery work may finish later, but must not replace
  /// that capture's progress or result.
  private var statusOwnerSessionID: UUID?
  private let speakerCapture = MeetingAccessibilityCapture()
  private var audioCapture: MeetingAudioCaptureService?
  private var stopTask: Task<Void, Never>?
  private var activeCaptureStopAtMs: Int64?
  private var boundaryUnobservableChecks = 0
  private var boundaryCheckInProgress = false
  /// Retained recordings that stopped retrying automatically and wait for
  /// the user to choose Retry. Kept visible so idle status cannot hide them.
  private var heldSessionIDs: Set<UUID> = []
  private var activeOverlapDetected = false
  private var captureTransitionInProgress = false
  private var heartbeatTask: Task<Void, Never>?
  private var lastFailureCode: String?
  private var didStart = false

  private(set) var status: MeetingMenuBarStatus = .uncovered
  private(set) var statusDetail = "Pair a healthy Mac with Atlas to cover meetings."
  private(set) var speakerDetectionDetail = "Speaker names use native Meet activity when available."
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
    clientProvider: (() -> (any MeetingAtlasClient)?)? = nil,
    joinedMeetingProvider: (@Sendable (String?) async -> Bool)? = nil,
    tokenReader: @escaping @Sendable () -> String? = { MeetingCaptureTokenStore().read() },
    diskStateReader: @escaping @Sendable () -> String = { MeetingCaptureCoordinator.readLocalDiskState() }
  ) {
    self.settings = settings
    self.microphonePermission = microphonePermission
    self.transcription = transcription
    self.clientProvider = clientProvider
    self.joinedMeetingProvider = joinedMeetingProvider
    self.tokenReader = tokenReader
    self.diskStateReader = diskStateReader
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

  /// Recordings saved on this Mac that wait for a manual Retry.
  var heldRecordingCount: Int { heldSessionIDs.count }

  var isCapturing: Bool { activeSessionID != nil }
  var isCaptureTransitioning: Bool { captureTransitionInProgress }
  var hasScheduledUploadRetry: Bool { retryTask != nil }
  var hasActiveRecoveryBatch: Bool { uploadTask != nil }

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
    Task { @MainActor [weak self] in await self?.updateUnpairedStatus() }
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
    if let sessionID = activeSessionID, let capture = audioCapture, !captureTransitionInProgress {
      // Quitting: make the recording durable now; delivery resumes on the
      // next launch instead of racing process exit.
      beginFinishingCapture(sessionID: sessionID, capture: capture)
    }
    // Also covers a user Stop that is still flushing when Quit arrives.
    if let finishing = finishingCaptureTask {
      let drain = Task { _ = await finishing.result }
      _ = await waitForShutdownTask(drain, timeout: Self.shutdownCaptureDrainSeconds)
    }
    uploadTask?.cancel()
    retryTask?.cancel()
  }

  func toggleManualCapture() {
    guard !captureTransitionInProgress else { return }
    if activeSessionID != nil {
      Task { @MainActor [weak self] in await self?.stopCapture(userInitiated: true) }
    } else {
      suppressedEvents.removeAll()
      Task { @MainActor [weak self] in await self?.startCapture(intent: nil) }
    }
  }

  func startScheduledCapture(_ intent: AtlasCaptureScheduleIntent) {
    guard activeSessionID == nil, !captureTransitionInProgress else { return }
    suppressedEvents.release(eventID: intent.eventID)
    Task { @MainActor [weak self] in await self?.startCapture(intent: intent) }
  }

  func refreshSchedule() {
    Task { @MainActor [weak self] in await self?.pollSchedule() }
  }

  func retryPendingRecordings() {
    guard uploadTask == nil, deliveringSessions.isEmpty else { return }
    retryBackoff.reset()
    guard activeSessionID == nil, !captureTransitionInProgress else {
      // Scanning retained audio now would contend with the live recording's
      // chunk writes. Release held sessions once this capture has finished.
      releaseManualRetryHoldsOnNextScan = true
      scheduleUploadRetry()
      return
    }
    recoveryTask = Task { @MainActor [weak self] in
      await self?.recoverLocalSessions(releasingManualRetryHolds: true)
    }
  }

  func refreshConfiguration() {
    Task { @MainActor [weak self] in await self?.updateUnpairedStatus() }
  }

  private func scheduleLoop() async {
    while !Task.isCancelled {
      await pollSchedule()
      try? await Task.sleep(nanoseconds: Self.schedulePollSeconds * 1_000_000_000)
    }
  }

  func pollSchedule() async {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    suppressedEvents.prune(nowMs: now)
    // A timer can fire late after system sleep. Re-check the calendar stop
    // boundary against the wall clock on every poll.
    if activeSessionID != nil, !captureTransitionInProgress, !boundaryCheckInProgress,
       let stopAt = activeCaptureStopAtMs, now >= stopAt {
      scheduleCaptureStop(atMs: now)
    }
    let intents: [AtlasCaptureScheduleIntent]
    var scheduleFetchFailed = false
    if let client = await atlasClient() {
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
        await updateUnpairedStatus()
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
        publishIdleStatus("Ready to record. Automatic recording is off.")
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
          && !suppressedEvents.isSuppressed($0.eventID, nowMs: now)
      })
    else {
      if !isBusy && !scheduleFetchFailed {
        guard await atlasClient() != nil, !isBusy else { return }
        publishIdleStatus("Ready for the next scheduled meeting.")
      }
      return
    }
    guard await hasJoinedMeeting(url: next.meetingURL) else {
      if !isBusy {
        status = .covered
        statusDetail = "Waiting for you to join the scheduled meeting."
      }
      return
    }
    guard settings.meetingModeEnabled, !Task.isCancelled,
          activeSessionID == nil, !captureTransitionInProgress else { return }
    if next.overlapsPrevious {
      status = .attention
      statusDetail = "Overlapping calendar meetings need one shared capture session."
    }
    await startCapture(intent: next)
  }

  private func hasJoinedMeeting(url: String?) async -> Bool {
    if let joinedMeetingProvider { return await joinedMeetingProvider(url) }
    return await meetingAccessibilityAvailability(for: url) == .available
  }

  private func meetingAccessibilityAvailability(for url: String?) async -> MeetingAccessibilityAvailability {
    guard let url, let expected = URL(string: url), expected.scheme == "https",
          expected.host == "meet.google.com" else { return .noMeeting }
    let pids = NSWorkspace.shared.runningApplications.filter {
      $0.bundleIdentifier == "com.google.Chrome" ||
      $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
    }.map(\.processIdentifier)
    // Speaker capture only supports Chrome, so with no Chrome process the call
    // cannot still be open there; reporting it as unreadable instead would keep
    // a scheduled recording running after the user quits the browser.
    guard !pids.isEmpty else { return .noMeeting }
    let result = await Task.detached(priority: .utility) {
      MeetingAccessibilityReader.read(pids: pids)
    }.value
    guard let snapshot = result.snapshot else { return result.availability }
    return snapshot.meetingID == expected.path ? .available : .noMeeting
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
      // The continuous clock keeps counting while the Mac sleeps, so a lid
      // closed past the boundary stops promptly on wake.
      try? await Task.sleep(for: .milliseconds(delay), clock: .continuous)
      guard !Task.isCancelled else { return }
      self?.stopTask = nil
      await self?.stopCaptureAtCalendarBoundary()
    }
  }

  private func stopCaptureAtCalendarBoundary() async {
    guard let intent = activeIntent, intent.meetingURL != nil else {
      await stopCapture()
      return
    }
    // The AX read below can be slow; a schedule poll during it must not start
    // a second, concurrent check that counts the same interval twice.
    guard !boundaryCheckInProgress, let sessionID = activeSessionID else { return }
    boundaryCheckInProgress = true
    defer { boundaryCheckInProgress = false }
    let availability = await meetingAccessibilityAvailability(for: intent.meetingURL)
    guard activeSessionID == sessionID, !captureTransitionInProgress else { return }
    boundaryUnobservableChecks = MeetingCaptureStopPolicy.nextUnobservableBoundaryCount(
      after: boundaryUnobservableChecks, availability: availability
    )
    guard MeetingCaptureStopPolicy.shouldStopAtCalendarBoundary(
      availability, unobservableChecks: boundaryUnobservableChecks
    ) else {
      status = .recording
      statusDetail = "The meeting is still open; recording continues."
      scheduleCaptureStop(atMs: Int64(Date().timeIntervalSince1970 * 1_000) + Self.stopGraceMs)
      return
    }
    await stopCapture()
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
    guard await localDiskState() == "ready" else {
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

    // Load the encryption key off the main actor before recording, so a
    // locked keychain or a pending prompt fails the start instead of every
    // chunk write later.
    let store = self.store
    do {
      try await Task.detached(priority: .userInitiated) { try store.prepareEncryptionKey() }.value
    } catch {
      lastFailureCode = "encryption_key"
      status = .uncovered
      statusDetail = "The meeting recording encryption key is unavailable. Unlock the login keychain and try again."
      DiagnosticsService.capture(error: error, category: "storage", code: "meeting_key")
      return
    }

    // A fresh capture takes priority over background recovery. Local processing
    // checks cancellation between bounded transcription windows, while every
    // encrypted source chunk and upload receipt remains durable for retry.
    prioritizeFreshCaptureOverRecovery()

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
      capture.onActivity = { [weak assistant] input in
        assistant?.recordActivity(input)
      }
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
      capture.onMicrophoneConfirmed = { [weak self] in
        guard let self, self.activeSessionID == sessionID,
              self.statusDetail == Self.microphonePendingDetail else { return }
        self.status = .recording
        self.statusDetail = self.activeIntent == nil ? "Recording ad hoc meeting." : "Recording scheduled meeting."
      }
      try await capture.start(selection: settings.selectedInput)
      speakerCapture.onStatus = { [weak self] detail in
        guard let self, self.speakerDetectionDetail != detail else { return }
        self.speakerDetectionDetail = detail
      }
      speakerCapture.start(sessionID: sessionID, startMs: capture.captureStartedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000), store: store, expectedMeetingURL: intent?.meetingURL)
      self.audioCapture = capture
      self.activeSessionID = sessionID
      self.statusOwnerSessionID = sessionID
      self.activeIntent = intent
      self.activeOverlapDetected = intent?.overlapsPrevious ?? false
      self.activeMeetingTitle = intent?.title ?? "Ad hoc meeting"
      assistant.begin(sessionID: sessionID, title: self.activeMeetingTitle ?? "Ad hoc meeting",
                      scheduledEndAt: intent.map { Date(timeIntervalSince1970: Double($0.endMs) / 1_000) })
      lastFailureCode = nil
      if activeOverlapDetected {
        status = .attention
        statusDetail = "Overlapping meetings share one physical audio capture."
      } else if !capture.isMicrophoneConfirmed {
        status = .attention
        statusDetail = Self.microphonePendingDetail
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
      // Keep any written chunk encrypted and recoverable instead of deleting
      // evidence of a partial/uncovered meeting. A start that captured
      // nothing leaves no directory behind; the schedule poll may retry
      // every minute for the whole meeting window.
      retryBackoff.failed(sessionID, now: ProcessInfo.processInfo.systemUptime)
      if let manifest = try? store.loadManifest(sessionID: sessionID), !manifest.chunks.isEmpty {
        try? store.markState(sessionID: sessionID, state: .failed)
        scheduleUploadRetry()
      } else {
        try? store.removeSession(sessionID: sessionID)
      }
      status = .uncovered
      statusDetail = error.localizedDescription
      DiagnosticsService.capture(error: error, category: "audio", code: "meeting_start")
    }
  }

  private func stopCapture(userInitiated: Bool = false) async {
    guard let sessionID = activeSessionID,
          let capture = audioCapture,
          !captureTransitionInProgress else { return }
    if userInitiated {
      suppressAutomaticRestart(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
    }
    let finishing = beginFinishingCapture(sessionID: sessionID, capture: capture)

    do {
      try await finishing.value
      await deliver(sessionID: sessionID)
    } catch {
      lastFailureCode = "local_processing"
      if canPublishStatus(for: sessionID) {
        status = .attention
        statusDetail = "Audio is retained locally for repair after processing failed."
      }
      retryBackoff.failed(sessionID, now: ProcessInfo.processInfo.systemUptime)
      scheduleUploadRetry()
      DiagnosticsService.capture(error: error, category: "storage", code: "meeting_process")
    }
  }

  /// A manual stop means "off the record": the schedule poll must not start
  /// a new capture for the stopped event, or an overlapping one, while its
  /// window is still open. A different call that has not started yet (for
  /// example the next back-to-back meeting in its pre-arm window) is not
  /// suppressed.
  private func suppressAutomaticRestart(nowMs: Int64) {
    var stopped = scheduleIntents.filter { intent in
      guard intent.startMs - Self.preArmWindowMs <= nowMs,
            nowMs <= intent.endMs + Self.stopGraceMs else { return false }
      guard let activeIntent else {
        // An ad hoc capture covered whatever call was already in progress.
        return intent.startMs <= nowMs
      }
      if let url = activeIntent.meetingURL, intent.meetingURL == url { return true }
      return intent.startMs <= nowMs
        && intent.startMs < activeIntent.endMs && intent.endMs > activeIntent.startMs
    }
    if let activeIntent { stopped.append(activeIntent) }
    for intent in stopped {
      suppressedEvents.suppress(eventID: intent.eventID, untilMs: intent.endMs + Self.stopGraceMs)
    }
  }

  /// Stops the audio stream and makes the session durable for delivery. It
  /// runs as its own task so app shutdown can await it (bounded) without
  /// waiting for, or cancelling into, transcription and upload.
  @discardableResult
  private func beginFinishingCapture(
    sessionID: UUID,
    capture: MeetingAudioCaptureService
  ) -> Task<Void, Error> {
    captureTransitionInProgress = true
    stopTask?.cancel()
    stopTask = nil
    activeCaptureStopAtMs = nil
    boundaryUnobservableChecks = 0
    activeOverlapDetected = false
    activeSessionID = nil
    audioCapture = nil
    activeIntent = nil
    status = .uploading
    statusDetail = "Finishing local recording and transcription."
    assistant.end(sessionID: sessionID)

    let store = self.store
    let speakerCapture = self.speakerCapture
    let task = Task { @MainActor [weak self] in
      // Release the capture transition only after the stream has stopped. A
      // schedule poll can then start a genuinely separate meeting while the
      // finished session is transcribed/uploaded.
      defer {
        self?.captureTransitionInProgress = false
        self?.finishingCaptureTask = nil
      }
      do {
        _ = try await capture.stop()
      } catch {
        // The speaker poller must stop even when the final flush fails, or
        // it keeps reading Chrome's AX tree for a dead session.
        await speakerCapture.stop()
        try? store.markState(sessionID: sessionID, state: .failed)
        throw error
      }
      await speakerCapture.stop()
      do {
        let manifest = try store.loadManifest(sessionID: sessionID)
        let durationMs = manifest.chunks.map(\.endMs).max() ?? 0
        try store.markState(
          sessionID: sessionID,
          state: .awaitingTranscription,
          durationMs: durationMs,
          sourceGapDetected: capture.sourceGapDetected
        )
      } catch {
        try? store.markState(sessionID: sessionID, state: .failed)
        throw error
      }
    }
    finishingCaptureTask = task
    return task
  }

  private var deliveringSessions: Set<UUID> = []

  func deliver(sessionID: UUID) async {
    guard !deliveringSessions.contains(sessionID) else { return }
    deliveringSessions.insert(sessionID)
    defer { deliveringSessions.remove(sessionID) }
    guard let client = await atlasClient() else {
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
      let completedManifest = try store.loadManifest(sessionID: sessionID)
      if let meetingReference = completedManifest.atlasMeetingID {
        await assistant.finalize(
          sessionID: sessionID,
          meetingReference: meetingReference,
          durationMilliseconds: completedManifest.durationMs ?? 0
        )
      }
      try store.removeSession(sessionID: sessionID)
      heldSessionIDs.remove(sessionID)
      retryBackoff.succeeded(sessionID)
    } catch {
      if Task.isCancelled || error is CancellationError {
        try? store.markState(sessionID: sessionID, state: .awaitingTranscription)
        scheduleUploadRetry()
        return
      }
      retryBackoff.failed(sessionID, now: ProcessInfo.processInfo.systemUptime)
      let failure = MeetingDeliveryFailurePolicy.classify(error)
      let held = (try? store.recordDeliveryFailure(
        sessionID: sessionID,
        countsTowardLimit: failure != .transient,
        holdImmediately: failure == .permanent,
        maximumAttempts: MeetingDeliveryFailurePolicy.maximumAutomaticAttempts
      )) ?? false
      if held { heldSessionIDs.insert(sessionID) }
      if canPublishStatus(for: sessionID) {
        lastFailureCode = "meeting_delivery"
        status = .attention
        statusDetail = held
          ? "Meeting saved locally but could not be processed. \(error.localizedDescription) Choose Retry to try again."
          : "Meeting saved locally. \(error.localizedDescription) Will retry automatically."
      }
      DiagnosticsService.capture(error: error, category: "network", code: "meeting_delivery")
      scheduleUploadRetry()
    }
  }

  func prioritizeFreshCaptureOverRecovery() {
    MeetingRecoveryPriority.cancelActiveBatch(&uploadTask)
    uploadTaskID = nil
    // Keep the sleeping retry scheduler alive. Its active-capture guard pauses
    // delivery without losing the durable retry trigger after this meeting.
  }

  func scheduleUploadRetry() {
    if retryTask != nil {
      // A long cooldown sleep must not delay a newly failed recording's
      // first retry; restart the scheduler. Never interrupt a running batch.
      guard retryTaskSleepsForBackoff else { return }
      retryTask?.cancel()
      retryTask = nil
    }
    let taskID = UUID()
    retryTaskID = taskID
    retryTaskSleepsForBackoff = false
    retryTask = Task { @MainActor [weak self] in
      defer {
        if let self, self.retryTaskID == taskID {
          self.retryTask = nil
          self.retryTaskID = nil
          self.retryTaskSleepsForBackoff = false
        }
      }
      var delaySeconds = Self.retryPollSeconds
      while !Task.isCancelled {
        self?.retryTaskSleepsForBackoff = delaySeconds > Self.retryPollSeconds
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        delaySeconds = Self.retryPollSeconds
        guard !Task.isCancelled, let self else { return }
        self.retryTaskSleepsForBackoff = false
        guard self.canRunBackgroundRecovery else { continue }
        // Nothing can be delivered while unpaired; do not rescan retained
        // audio every minute for it.
        guard await self.atlasClient() != nil, self.canRunBackgroundRecovery else { continue }
        do {
          let releasing = self.releaseManualRetryHoldsOnNextScan
          let pending = try await self.scanRecoverySessions(releasingManualRetryHolds: releasing)
            .filter(self.isAutomaticallyRetryable)
          if releasing { self.releaseManualRetryHoldsOnNextScan = false }
          guard !Task.isCancelled else { return }
          guard self.canRunBackgroundRecovery else { continue }
          guard !pending.isEmpty else { return }
          // Every pending recording is cooling down: sleep until the first is
          // ready instead of rescanning each minute.
          let now = ProcessInfo.processInfo.systemUptime
          if let readyAt = self.retryBackoff.nextReadyTime(among: pending.map(\.sessionID), now: now) {
            delaySeconds = max(Self.retryPollSeconds, readyAt - now)
            continue
          }
          guard let batch = self.startRecoveryBatch(pending) else { continue }
          await batch.value
          let stillPending = try await self.scanRecoverySessions().contains(where: self.isAutomaticallyRetryable)
          if !stillPending { return }
        } catch is CancellationError {
          return
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

  /// Background recovery waits while a capture starts, runs, or flushes: a
  /// scan would contend with its chunk writes, and a `.recording` session
  /// that is being stopped must not be delivered twice.
  private var canRunBackgroundRecovery: Bool {
    activeSessionID == nil && !captureTransitionInProgress && deliveringSessions.isEmpty
  }

  /// Any retained session other than the live one can be retried, including
  /// one left in `.recording` by a crash. Sessions held for a manual retry
  /// are skipped until the user asks.
  private func isAutomaticallyRetryable(_ session: MeetingRecordingSessionManifest) -> Bool {
    !session.chunks.isEmpty && !session.awaitingManualRetry && session.sessionID != activeSessionID
  }

  func scanRecoverySessions(releasingManualRetryHolds: Bool = false) async throws -> [MeetingRecordingSessionManifest] {
    try Task.checkCancellation()
    // Recovery stats retained chunks and hashes unknown ones. Keep that
    // synchronous disk work off the main actor even when a retry wakes
    // during dictation.
    let store = self.store
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      return try store.recoverSessions(releasingManualRetryHolds: releasingManualRetryHolds)
    }
    let sessions = try await withTaskCancellationHandler {
      let sessions = try await worker.value
      try Task.checkCancellation()
      return sessions
    } onCancel: {
      worker.cancel()
    }
    heldSessionIDs = Set(sessions.filter { !$0.chunks.isEmpty && $0.awaitingManualRetry }.map(\.sessionID))
    return sessions
  }

  private func recoverLocalSessions(releasingManualRetryHolds: Bool = false) async {
    guard uploadTask == nil else { return }
    do {
      let sessions = MeetingRecordingSessionManifest.orderedForRecovery(
        try await scanRecoverySessions(releasingManualRetryHolds: releasingManualRetryHolds))
      guard !Task.isCancelled else { return }
      guard activeSessionID == nil else {
        scheduleUploadRetry()
        return
      }
      let pending = sessions.filter(isAutomaticallyRetryable)
      if !pending.isEmpty {
        _ = startRecoveryBatch(pending)
      } else if !isBusy {
        // After a relaunch, recordings held for a manual Retry are otherwise
        // invisible: nothing retries them automatically.
        publishHeldRecordingsStatus()
      }
    } catch is CancellationError {
      return
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
      guard !session.chunks.isEmpty, !session.awaitingManualRetry else { continue }
      guard session.sessionID != activeSessionID,
            retryBackoff.isReady(session.sessionID, now: ProcessInfo.processInfo.systemUptime) else { continue }
      await deliver(sessionID: session.sessionID)
    }
  }

  @discardableResult
  func startRecoveryBatch(
    _ sessions: [MeetingRecordingSessionManifest]
  ) -> Task<Void, Never>? {
    startRecoveryOperation { [weak self] in
      guard let self else { return }
      await self.retryPendingSessions(sessions)
    }
  }

  func startRecoveryOperation(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never>? {
    guard uploadTask == nil else { return nil }
    let batchID = UUID()
    uploadTaskID = batchID
    let batch = Task { @MainActor [weak self] in
      guard let self else { return }
      await operation()
      self.finishRecoveryBatch(batchID)
    }
    uploadTask = batch
    return batch
  }

  func finishRecoveryBatch(_ batchID: UUID) {
    guard MeetingRecoveryBatchOwnership.shouldClear(
      completing: batchID,
      current: uploadTaskID
    ) else { return }
    uploadTask = nil
    uploadTaskID = nil
  }

  func atlasClient() async -> MeetingAtlasClient? {
    if let clientProvider { return clientProvider() }
    guard let baseURL = URL(string: settings.atlasBaseURL),
      baseURL.scheme == "https",
      let token = await Task.detached(priority: .utility, operation: tokenReader).value,
      !token.isEmpty
    else { return nil }
    return URLSessionMeetingAtlasClient(baseURL: baseURL, token: token)
  }

  private func heartbeatLoop() async {
    while !Task.isCancelled {
      await sendHeartbeat()
      await stopCaptureIfStorageExhausted()
      try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
    }
  }

  /// Free space is checked only at start, but a long meeting writes about
  /// 0.7 GB per hour. Stop cleanly, keeping every written chunk, before
  /// writes begin to fail.
  private func stopCaptureIfStorageExhausted() async {
    guard activeSessionID != nil else { return }
    let diskState = await localDiskState()
    guard diskState == "full", activeSessionID != nil, !captureTransitionInProgress else { return }
    lastFailureCode = "disk_full"
    Task { @MainActor [weak self] in await self?.stopCapture() }
  }

  private func sendHeartbeat() async {
    guard let client = await atlasClient() else { return }
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
    let diskState = await localDiskState()
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

  func localDiskState() async -> String {
    // This API may synchronously wait on CacheDelete/XPC, even for a healthy disk.
    // Never let it occupy the executor used for dictation completion and paste.
    await Task.detached(priority: .utility, operation: diskStateReader).value
  }

  nonisolated static func readLocalDiskState() -> String {
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

  private func updateUnpairedStatus() async {
    guard !isBusy else { return }
    let client = await atlasClient()
    let diskState = await localDiskState()
    // A new recording may have started while either system service was responding.
    guard !isBusy, !Task.isCancelled else { return }
    guard Self.isSupportedMac else {
      status = .uncovered
      statusDetail = "Meeting Mode requires an Apple Silicon Mac."
      return
    }
    guard client != nil else {
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
    guard diskState == "ready" else {
      status = .uncovered
      statusDetail = "At least 500 MB of local storage is required before recording."
      return
    }
    if activeSessionID == nil {
      publishIdleStatus("Ready for the next scheduled meeting.")
    }
  }

  /// Idle "ready" status. Recordings held for a manual Retry stay visible
  /// instead of being replaced by a ready message on the next poll.
  private func publishIdleStatus(_ readyDetail: String) {
    guard !publishHeldRecordingsStatus() else { return }
    status = .covered
    statusDetail = readyDetail
  }

  @discardableResult
  private func publishHeldRecordingsStatus() -> Bool {
    let held = heldSessionIDs.count
    guard held > 0 else { return false }
    status = .attention
    statusDetail = held == 1
      ? "1 recording saved on this Mac could not be processed. Choose Retry to try again."
      : "\(held) recordings saved on this Mac could not be processed. Choose Retry to try again."
    return true
  }

  private func canPublishStatus(for sessionID: UUID) -> Bool {
    MeetingStatusPublicationPolicy.canPublish(
      sessionID: sessionID,
      activeSessionID: activeSessionID,
      statusOwnerSessionID: statusOwnerSessionID
    )
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

enum MeetingDeliveryFailure: Equatable {
  /// Network or Atlas availability. Cheap to retry: audio upload is resumable
  /// and a finished transcript is checkpointed.
  case transient
  /// May repeat full local transcription; counts toward the attempt limit.
  case counted
  /// Deterministic for this recording; retrying cannot succeed on its own.
  case permanent
}

enum MeetingDeliveryFailurePolicy {
  static let maximumAutomaticAttempts = 4

  static func classify(_ error: Error) -> MeetingDeliveryFailure {
    if case TranscriptionError.emptyTranscript = error { return .permanent }
    if let storeError = error as? MeetingChunkStoreError {
      switch storeError {
      case .encryptionFailed, .keychain: return .transient
      case .invalidSession, .invalidChunk, .missingManifest, .missingChunk, .checksumMismatch:
        return .permanent
      }
    }
    if error is URLError || error is MeetingAtlasClientError { return .transient }
    return .counted
  }
}

enum MeetingRecoveryPriority {
  static func cancelActiveBatch(_ batch: inout Task<Void, Never>?) {
    batch?.cancel()
    batch = nil
  }
}

enum MeetingRecoveryBatchOwnership {
  static func shouldClear(completing: UUID, current: UUID?) -> Bool {
    completing == current
  }
}

enum MeetingStatusPublicationPolicy {
  static func canPublish(
    sessionID: UUID,
    activeSessionID: UUID?,
    statusOwnerSessionID: UUID?
  ) -> Bool {
    if let activeSessionID { return sessionID == activeSessionID }
    if let statusOwnerSessionID { return sessionID == statusOwnerSessionID }
    return true
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
