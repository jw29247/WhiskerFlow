@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Logging
import ScreenCaptureKit
import WhiskerFlowAppSupport
import WhiskerFlowCore

enum MeetingAudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case displayUnavailable
    case streamStartFailed(String)
    case streamRestartFailed(String)
    case sampleConversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "The microphone is unavailable."
        case .displayUnavailable: return "No Mac display is available for system-audio capture."
        case .streamStartFailed(let message): return "Mac audio capture could not start: \(message)"
        case .streamRestartFailed(let message): return "Mac audio capture could not resume: \(message)"
        case .sampleConversionFailed: return "Mac audio could not be normalized for recording."
        }
    }
}

/// Captures microphone and Mac output independently, then writes a mixed track
/// from aligned 16 kHz mono samples. ScreenCaptureKit is used only for its audio
/// output; no screen frames are retained or uploaded.
@MainActor
final class MeetingAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private let microphone: AudioCaptureService
    private let writer: MeetingPCMChunkWriter
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingAudioCapture")
    private let microphonePending = LockedAudioBuffer()
    private let systemPending = LockedAudioBuffer()
  private var stream: SCStream?
  private var isRunning = false
  private var acceptingSamples = false
    /// Gates only the microphone during a re-arm. System audio (the remote
    /// participants) keeps flowing to its own track meanwhile.
    private var acceptingMicrophoneSamples = false
    private var microphoneSelection: AudioInputSelection?
    /// The user's choice, re-resolved on every re-arm so a reconnected
    /// headset is picked up again and an unplugged one falls back.
    private var preferredMicrophoneSelection: AudioInputSelection?
    /// Set after a source was interrupted. Its next samples are preceded by
    /// silence so every track keeps the same timeline.
    private var microphoneNeedsAlignment = false
    private var systemNeedsAlignment = false
    private var mixGapDetected = false
    /// Chunk encryption and file I/O run here, off the main actor and off the
    /// real-time audio thread. The queue is serial, so each track's samples
    /// stay in order and `finish()` runs after every queued append.
    private let writerQueue = DispatchQueue(
        label: "agency.thatworks.WhiskerFlow.meeting-writer",
        qos: .userInitiated
    )
    private var microphoneRecoveryTask: Task<Void, Never>?
    private var microphoneRecoveryFailed = false
    private var systemStreamRecoveryTask: Task<Void, Never>?
    private var systemStreamRecoveryFailed = false
    private var systemStreamNeedsRestart = false
    private var activityTask: Task<Void, Never>?
    private var activityStartedAt: TimeInterval?
    private var microphoneActivity = false
    private var systemActivity = false
    private var sawMicrophoneSamples = false
    private var sawSystemSamples = false
    private var sleepActivity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
  private var microphoneSampleCount = 0
    private var systemSampleCount = 0

    private(set) var captureStartedAtMs: Int64?
    /// False when capture started without a microphone confirmed to deliver
    /// audio; Mac audio is still recorded and the session reports a gap.
    private(set) var isMicrophoneConfirmed = false

    var onFailure: ((Error) -> Void)?
    var onActivity: ((MeetingActivityInput) -> Void)?
    /// Normalised 16 kHz microphone samples, for the private coach's on-device
    /// pace analysis. Never written anywhere by this hook.
    var onMicrophoneSamples: (([Float]) -> Void)?
    /// Called once when a microphone that started unconfirmed delivers its
    /// first samples, for example a slow Bluetooth headset.
    var onMicrophoneConfirmed: (() -> Void)?

    init(
        microphone: AudioCaptureService? = nil,
        store: EncryptedMeetingChunkStore,
        sessionID: UUID
    ) {
        self.microphone = microphone ?? AudioCaptureService()
        self.writer = MeetingPCMChunkWriter(store: store, sessionID: sessionID)
        super.init()
        self.microphone.onConfigurationChange = { [weak self] in
            self?.handleMicrophoneConfigurationChange()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemSleep()
            }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }
    }

    static func availableMicrophoneSelection(_ preferred: AudioInputSelection, availableUIDs: Set<String>) -> AudioInputSelection {
        if case .device(let uid) = preferred, !availableUIDs.contains(uid) { return .systemDefault }
        return preferred
    }

    func start(selection: AudioInputSelection) async throws {
        guard !isRunning else { return }
        preferredMicrophoneSelection = selection
        let selection = Self.availableMicrophoneSelection(selection, availableUIDs: Set(CoreAudioDeviceCatalog.availableInputs().map(\.uid)))
        microphoneSelection = selection
        microphoneRecoveryFailed = false
        systemStreamRecoveryFailed = false
        systemStreamNeedsRestart = false
        microphoneNeedsAlignment = false
        systemNeedsAlignment = false
        mixGapDetected = false
        microphone.onSamples = { [weak self] samples in
          guard let self else { return }
          guard self.acceptingSamples, self.acceptingMicrophoneSamples else { return }
          self.sawMicrophoneSamples = true
          if !self.isMicrophoneConfirmed {
              self.isMicrophoneConfirmed = true
              self.onMicrophoneConfirmed?()
          }
          self.microphoneActivity = self.microphoneActivity || Self.hasAudibleActivity(samples)
          if self.microphoneNeedsAlignment {
              self.microphoneNeedsAlignment = false
              self.alignAfterInterruption(.microphone)
          }
          // Source timelines are kept aligned by explicit silence padding
          // after an interruption; a sample-count "start time" cannot reveal
          // a gap by itself.
          self.enqueueWrite(samples, track: .microphone)
          self.onMicrophoneSamples?(samples)
          self.microphoneSampleCount += samples.count
          self.microphonePending.append(samples)
          self.mixAvailable()
        }
        do {
            let stream = try await makeSystemStream()
            // Resolve ScreenCaptureKit's shareable content before opening the
            // microphone, then arm both callbacks only after the system stream
            // is running. Samples observed during either startup phase are
            // discarded instead of creating an unaligned prefix.
            microphoneSampleCount = 0
            systemSampleCount = 0
            self.stream = stream
            try await stream.startCapture()
            do {
                let armed = try await startWorkingMicrophone(selection: selection)
                microphoneSelection = armed.selection
                isMicrophoneConfirmed = armed.confirmed
                // A slow transport may start delivering after startup; its
                // first samples are then aligned with the system track.
                microphoneNeedsAlignment = !armed.confirmed
                acceptingMicrophoneSamples = true
            } catch let error as CancellationError {
                throw error
            } catch {
                // No input could be opened (for example a Mac mini without a
                // microphone). Record Mac audio alone with an honest source
                // gap instead of failing every schedule poll for the meeting.
                logger.error(
                    "Meeting Mode microphone unavailable; recording Mac audio only",
                    metadata: ["error": "\(error.localizedDescription)"]
                )
                microphoneSelection = nil
                isMicrophoneConfirmed = false
                acceptingMicrophoneSamples = false
                microphoneRecoveryFailed = true
            }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "WhiskerFlow Meeting Mode capture"
            )
            captureStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            acceptingSamples = true
            isRunning = true
            startActivityUpdates()
          } catch {
            acceptingSamples = false
            if let activeStream = self.stream {
              try? await activeStream.stopCapture()
            }
            self.stream = nil
            acceptingMicrophoneSamples = false
            endSleepActivity()
            // This service is discarded after a failed start; do not leave its
            // sleep/wake observers registered with NSWorkspace.
            removeWorkspaceObservers()
            microphone.cancel()
            microphone.onSamples = nil
            if let error = error as? MeetingAudioCaptureError { throw error }
            throw MeetingAudioCaptureError.streamStartFailed(error.localizedDescription)
        }
  }

    /// Bluetooth HFP and some USB interfaces take seconds to deliver a first
    /// buffer, more on a slow Mac. Allow the preferred input that long before
    /// moving to a fallback.
    static let preferredMicrophoneFlowTimeoutSeconds: Double = 6
    static let fallbackMicrophoneFlowTimeoutSeconds: Double = 3

    /// Candidate inputs in preference order: the requested input, then the
    /// built-in microphone, then the system default. Duplicates are removed.
    static func microphoneCandidates(
        for selection: AudioInputSelection,
        builtInUID: String?
    ) -> [AudioInputSelection] {
        var candidates = [selection]
        if let builtInUID { candidates.append(.device(uid: builtInUID)) }
        candidates.append(.systemDefault)
        var seen: [AudioInputSelection] = []
        for candidate in candidates where !seen.contains(candidate) { seen.append(candidate) }
        return seen
    }

    /// Bluetooth inputs can start an engine without producing any buffers.
    /// Confirm that audio is flowing before announcing a recording; fall back
    /// to the built-in or default input if a disconnected/silent transport
    /// never starts. When nothing is confirmed, the preferred input is left
    /// running unconfirmed; throws only when no input can be opened at all.
    private func startWorkingMicrophone(
        selection: AudioInputSelection
    ) async throws -> (selection: AudioInputSelection, confirmed: Bool) {
        let candidates = Self.microphoneCandidates(
            for: selection,
            builtInUID: CoreAudioDeviceCatalog.builtInInput()?.uid
        )
        var firstStarted: AudioInputSelection?
        var lastError: Error = MeetingAudioCaptureError.microphoneUnavailable
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                // An unplugged device throws here; continue to the fallbacks.
                try await microphone.start(selection: candidate, retainSamples: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                continue
            }
            firstStarted = firstStarted ?? candidate
            let timeout = index == 0
                ? Self.preferredMicrophoneFlowTimeoutSeconds
                : Self.fallbackMicrophoneFlowTimeoutSeconds
            if try await microphoneIsFlowing(timeoutSeconds: timeout) { return (candidate, true) }
        }
        guard let firstStarted else { throw lastError }
        try Task.checkCancellation()
        try await microphone.start(selection: firstStarted, retainSamples: false)
        return (firstStarted, false)
    }

    private func microphoneIsFlowing(timeoutSeconds: Double) async throws -> Bool {
        let attempts = max(1, Int((timeoutSeconds * 10).rounded()))
        for _ in 0..<attempts {
            if microphone.sampleCount() > 0 { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return microphone.sampleCount() > 0
    }

  func stop() async throws -> [MeetingRecordingChunkDescriptor] {
    acceptingSamples = false
    acceptingMicrophoneSamples = false
    isRunning = false
    stopActivityUpdates()
    microphoneRecoveryTask?.cancel()
    microphoneRecoveryTask = nil
    systemStreamRecoveryTask?.cancel()
    systemStreamRecoveryTask = nil
    if let stream {
      try? await stream.stopCapture()
    }
        self.stream = nil
        systemStreamNeedsRestart = false
        removeWorkspaceObservers()
        endSleepActivity()
        _ = microphone.stop(reason: .userReleased)
        microphone.onSamples = nil
        microphoneSelection = nil
        preferredMicrophoneSelection = nil
        mixAvailable(flushRemainder: true)
        let writer = self.writer
        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                continuation.resume(with: Result { try writer.finish() })
            }
        }
    }

    func cancel() async {
        acceptingSamples = false
        acceptingMicrophoneSamples = false
        isRunning = false
        stopActivityUpdates()
        microphoneRecoveryTask?.cancel()
        microphoneRecoveryTask = nil
        systemStreamRecoveryTask?.cancel()
        systemStreamRecoveryTask = nil
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        systemStreamNeedsRestart = false
        removeWorkspaceObservers()
        endSleepActivity()
        microphone.cancel()
        microphone.onSamples = nil
        microphoneSelection = nil
        preferredMicrophoneSelection = nil
        // A discarded session must not receive a late chunk write.
        await withCheckedContinuation { continuation in writerQueue.async { continuation.resume() } }
    }

    var sourceGapDetected: Bool {
        writer.sourceGapDetected
            || mixGapDetected
            || microphoneRecoveryFailed
            || systemStreamRecoveryFailed
            || Self.sourceCountsDiverge(microphone: microphoneSampleCount, system: systemSampleCount)
    }

    /// Whether the two source tracks ended at materially different lengths,
    /// for example a microphone that never delivered or stopped mid-call.
    /// The tolerance covers buffering plus device-clock drift (200 ppm).
    nonisolated static func sourceCountsDiverge(microphone: Int, system: Int) -> Bool {
        let tolerance = max(MeetingPCMChunkWriter.sampleRate, max(microphone, system) / 5_000)
        return abs(microphone - system) > tolerance
    }

    private func handleSystemSleep() {
        guard isRunning else { return }
        systemStreamNeedsRestart = true
        logger.info("Display sleep will interrupt Meeting Mode system capture")
    }

    private func handleSystemWake() {
        guard isRunning, systemStreamNeedsRestart else { return }
        logger.warning("Display woke; restarting Meeting Mode system capture")
        scheduleSystemStreamRecovery()
    }

    private func scheduleSystemStreamRecovery() {
        guard isRunning, systemStreamRecoveryTask == nil else { return }

        systemStreamRecoveryTask = Task { @MainActor [weak self] in
            defer { self?.systemStreamRecoveryTask = nil }
            var lastError: Error?
            for attempt in 0..<6 {
                guard let self, self.isRunning else { return }
                do {
                    if attempt > 0 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    try await self.restartSystemStream()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    lastError = error
                    self.logger.warning(
                        "System stream re-arm attempt failed",
                        metadata: [
                            "attempt": "\(attempt + 1)",
                            "error": "\(error.localizedDescription)",
                        ]
                    )
                }
            }

            guard let self, self.isRunning else { return }
            self.systemStreamRecoveryFailed = true
            self.systemStreamNeedsRestart = false
            self.logger.error(
                "System stream re-arm failed",
                metadata: ["error": "\(lastError?.localizedDescription ?? "unknown")"]
            )
            self.onFailure?(
                MeetingAudioCaptureError.streamRestartFailed(
                    lastError?.localizedDescription ?? "unknown"
                )
            )
        }
    }

    private func restartSystemStream() async throws {
        guard isRunning else { return }
        let previousStream = stream
        stream = nil
        try? await previousStream?.stopCapture()

        guard isRunning else { return }
        let replacement = try await makeSystemStream()
        try await replacement.startCapture()
        guard isRunning else {
            try? await replacement.stopCapture()
            return
        }

        // Keep the pending mix input: the aligned prefix is still valid, and
        // the first new system samples are preceded by silence for the
        // outage so the mixed and system tracks keep the microphone timeline.
        systemNeedsAlignment = true
        stream = replacement
        systemStreamNeedsRestart = false
        logger.info("System stream re-armed for Meeting Mode")
    }

    private func makeSystemStream() async throws -> SCStream {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw MeetingAudioCaptureError.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = MeetingPCMChunkWriter.sampleRate
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // A display-filtered SCStream still produces video frames even when
        // Meeting Mode only needs audio. Register a no-op screen sink so
        // ScreenCaptureKit has a consumer for that output.
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(
                label: "agency.thatworks.WhiskerFlow.meeting-screen",
                qos: .utility
            )
        )
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "agency.thatworks.WhiskerFlow.meeting-audio")
        )
        return stream
    }

    private func endSleepActivity() {
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
    }

    private func removeWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            workspaceCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            workspaceCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func handleMicrophoneConfigurationChange() {
        guard acceptingSamples,
              isRunning,
              let preferred = preferredMicrophoneSelection,
              microphoneRecoveryTask == nil else { return }

        // Pause only the microphone. System audio keeps writing its own track;
        // the microphone resumes behind silence for the re-arm window, so the
        // canonical mix never pairs pre- and post-change samples.
        acceptingMicrophoneSamples = false
        logger.warning("Microphone input changed; rearming Meeting Mode capture")

        microphoneRecoveryTask = Task { @MainActor [weak self] in
            defer { self?.microphoneRecoveryTask = nil }
            do {
                // CoreAudio needs a short settling window after Meet changes
                // the default aggregate input device.
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isRunning else { return }
                // Re-resolve: an unplugged headset falls back to the default
                // input, and a reconnected one is used again.
                let selection = Self.availableMicrophoneSelection(
                    preferred,
                    availableUIDs: Set(CoreAudioDeviceCatalog.availableInputs().map(\.uid))
                )
                let armed = try await self.startWorkingMicrophone(selection: selection)
                guard self.isRunning else { return }
                self.microphoneSelection = armed.selection
                self.microphoneNeedsAlignment = true
                self.acceptingMicrophoneSamples = true
                if armed.confirmed {
                    self.logger.info("Microphone input re-armed for Meeting Mode")
                } else {
                    self.logger.warning("Microphone re-armed but not yet delivering audio")
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                // System-audio capture never paused, so the session is still
                // retained and uploaded with an honest source-gap status.
                self.microphoneRecoveryFailed = true
                self.logger.error(
                    "Microphone re-arm failed",
                    metadata: ["error": "\(error.localizedDescription)"]
                )
                self.onFailure?(error)
            }
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, let samples = Self.samples(from: sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard acceptingSamples else { return }
            sawSystemSamples = true
            systemActivity = systemActivity || Self.hasAudibleActivity(samples)
            if systemNeedsAlignment {
                systemNeedsAlignment = false
                alignAfterInterruption(.system)
            }
            enqueueWrite(samples, track: .system)
            systemSampleCount += samples.count
            systemPending.append(samples)
            mixAvailable()
        }
    }

    private func enqueueWrite(_ samples: [Float], track: MeetingAudioTrack) {
        guard !samples.isEmpty else { return }
        let writer = self.writer
        writerQueue.async { [weak self] in
            do {
                _ = try writer.append(samples, track: track)
            } catch {
                Task { @MainActor [weak self] in self?.onFailure?(error) }
            }
        }
    }

    private func enqueueSilence(_ count: Int, track: MeetingAudioTrack) {
        var remaining = count
        while remaining > 0 {
            let slice = min(remaining, MeetingPCMChunkWriter.chunkSampleCount)
            enqueueWrite([Float](repeating: 0, count: slice), track: track)
            remaining -= slice
        }
    }

    /// Samples by which a resumed source may trail the other before it is
    /// padded with silence.
    private static let alignmentToleranceSamples = MeetingPCMChunkWriter.sampleRate / 2

    /// Pads a source that was interrupted (microphone re-arm, ScreenCaptureKit
    /// restart, late first buffer) so its track and its pending mix input
    /// resume at the other source's position instead of shifting earlier.
    private func alignAfterInterruption(_ track: MeetingAudioTrack) {
        let isMicrophone = track == .microphone
        let own = isMicrophone ? microphoneSampleCount : systemSampleCount
        let reference = isMicrophone ? systemSampleCount : microphoneSampleCount
        let trackDeficit = reference - own
        if trackDeficit > Self.alignmentToleranceSamples {
            enqueueSilence(trackDeficit, track: track)
            if isMicrophone { microphoneSampleCount += trackDeficit } else { systemSampleCount += trackDeficit }
            mixGapDetected = true
            writer.markSourceGap()
        }
        let ownPending = isMicrophone ? microphonePending : systemPending
        let referencePending = isMicrophone ? systemPending : microphonePending
        let pendingDeficit = referencePending.count - ownPending.count
        if pendingDeficit > Self.alignmentToleranceSamples {
            ownPending.append([Float](repeating: 0, count: pendingDeficit))
            mixGapDetected = true
        }
    }

    private func startActivityUpdates() {
        activityTask?.cancel()
        activityStartedAt = ProcessInfo.processInfo.systemUptime
        microphoneActivity = false
        systemActivity = false
        sawMicrophoneSamples = false
        sawSystemSamples = false
        activityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, let startedAt = self.activityStartedAt else { return }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
                self.onActivity?(.init(
                    elapsedSeconds: max(0, elapsed - 1), durationSeconds: min(1, elapsed),
                    ownMicActivity: self.sawMicrophoneSamples ? self.microphoneActivity : nil,
                    systemActivity: self.sawSystemSamples ? self.systemActivity : nil
                ))
                self.microphoneActivity = false
                self.systemActivity = false
                self.sawMicrophoneSamples = false
                self.sawSystemSamples = false
            }
        }
    }

    private func stopActivityUpdates() {
        activityTask?.cancel()
        activityTask = nil
        activityStartedAt = nil
        microphoneActivity = false
        systemActivity = false
        sawMicrophoneSamples = false
        sawSystemSamples = false
    }

    nonisolated static func hasAudibleActivity(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        return meanSquare.squareRoot() >= 0.015
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard isRunning else { return }
            systemStreamNeedsRestart = true
            logger.warning(
                "System stream stopped; scheduling re-arm",
                metadata: ["error": "\(error.localizedDescription)"]
            )
            scheduleSystemStreamRecovery()
        }
    }

    /// How far one source's unmixed samples may run ahead before the silent
    /// source is padded. Bounds memory and keeps the canonical mixed track
    /// advancing when one source stalls or fails for the rest of the call.
    static let maximumPendingMixLagSamples = 2 * MeetingPCMChunkWriter.chunkSampleCount

    /// Silence to append to the lagging source so the mix can advance, or nil.
    /// On the final flush the shorter source is always padded so the mixed
    /// track covers the longest source.
    nonisolated static func mixPadding(
        microphonePending: Int,
        systemPending: Int,
        flushRemainder: Bool
    ) -> (track: MeetingAudioTrack, count: Int)? {
        let lag = microphonePending - systemPending
        guard lag != 0, flushRemainder || abs(lag) > maximumPendingMixLagSamples else { return nil }
        return lag > 0 ? (.system, lag) : (.microphone, -lag)
    }

    private func mixAvailable(flushRemainder: Bool = false) {
        if let padding = Self.mixPadding(
            microphonePending: microphonePending.count,
            systemPending: systemPending.count,
            flushRemainder: flushRemainder
        ) {
            let lagging = padding.track == .microphone ? microphonePending : systemPending
            lagging.append([Float](repeating: 0, count: padding.count))
            if padding.count > Self.alignmentToleranceSamples {
                mixGapDetected = true
                writer.markSourceGap()
            }
        }
        let available = min(microphonePending.count, systemPending.count)
        let count = flushRemainder ? available : (available / MeetingPCMChunkWriter.chunkSampleCount) * MeetingPCMChunkWriter.chunkSampleCount
        guard count > 0 else { return }
        let mic = microphonePending.drainPrefix(count)
        let system = systemPending.drainPrefix(count)
        let mixed = zip(mic, system).map { max(-1, min(1, ($0 + $1) * 0.5)) }
        enqueueWrite(mixed, track: .mixed)
    }

    nonisolated private static func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let firstStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard firstStatus == noErr, requiredSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            raw.deallocate()
        }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let channelCount = max(1, Int(first.mNumberChannels))
        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let values = data.bindMemory(to: Float.self, capacity: sampleCount)
        if channelCount == 1 { return Array(UnsafeBufferPointer(start: values, count: sampleCount)) }
        return stride(from: 0, to: sampleCount, by: channelCount).map { frame in
            var total: Float = 0
            for channel in 0..<channelCount { total += values[frame + channel] }
            return total / Float(channelCount)
        }
    }
}
