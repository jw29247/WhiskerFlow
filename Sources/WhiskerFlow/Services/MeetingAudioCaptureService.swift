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
    private var microphoneSelection: AudioInputSelection?
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

    var onFailure: ((Error) -> Void)?
    var onActivity: ((MeetingActivityInput) -> Void)?

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
        let selection = Self.availableMicrophoneSelection(selection, availableUIDs: Set(CoreAudioDeviceCatalog.availableInputs().map(\.uid)))
        microphoneSelection = selection
        microphoneRecoveryFailed = false
        systemStreamRecoveryFailed = false
        systemStreamNeedsRestart = false
        microphone.onSamples = { [weak self] samples in
          guard let self else { return }
          guard self.acceptingSamples else { return }
          self.sawMicrophoneSamples = true
          self.microphoneActivity = self.microphoneActivity || Self.hasAudibleActivity(samples)
          do {
                _ = try writer.append(
                    samples,
                    track: .microphone,
                    sourceStartMs: Int64(microphoneSampleCount / 16)
                )
                microphoneSampleCount += samples.count
                microphonePending.append(samples)
                try mixAvailable()
            } catch {
                onFailure?(error)
            }
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
            microphoneSelection = try await startWorkingMicrophone(selection: selection)
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "WhiskerFlow Meeting Mode capture"
            )
            acceptingSamples = true
            isRunning = true
            startActivityUpdates()
          } catch {
            acceptingSamples = false
            if let activeStream = self.stream {
              try? await activeStream.stopCapture()
            }
            self.stream = nil
            endSleepActivity()
            microphone.cancel()
            microphone.onSamples = nil
            if let error = error as? MeetingAudioCaptureError { throw error }
            throw MeetingAudioCaptureError.streamStartFailed(error.localizedDescription)
        }
  }

    /// Bluetooth inputs can start an engine without producing any buffers.
    /// Confirm that audio is flowing before announcing a recording; use the
    /// built-in input if a disconnected/silent transport never starts.
    private func startWorkingMicrophone(selection: AudioInputSelection) async throws -> AudioInputSelection {
        try microphone.start(selection: selection)
        if try await microphoneIsFlowing() { return selection }
        if let builtIn = CoreAudioDeviceCatalog.builtInInput(), selection != .device(uid: builtIn.uid) {
            let fallback = AudioInputSelection.device(uid: builtIn.uid)
            try microphone.start(selection: fallback)
            if try await microphoneIsFlowing() { return fallback }
        }
        throw MeetingAudioCaptureError.microphoneUnavailable
    }

    private func microphoneIsFlowing() async throws -> Bool {
        for _ in 0..<20 {
            if microphone.sampleCount() > 0 { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return microphone.sampleCount() > 0
    }

  func stop() async throws -> [MeetingRecordingChunkDescriptor] {
    acceptingSamples = false
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
        try mixAvailable(flushRemainder: true)
        return try writer.finish()
    }

    func cancel() async {
        acceptingSamples = false
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
    }

    var sourceGapDetected: Bool {
        writer.sourceGapDetected
            || microphoneRecoveryFailed
            || systemStreamRecoveryFailed
            || abs(microphonePending.count - systemPending.count) > MeetingPCMChunkWriter.sampleRate / 2
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

        microphonePending.reset()
        systemPending.reset()
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
              let selection = microphoneSelection,
              microphoneRecoveryTask == nil else { return }

        // Do not combine pre-reconfiguration system samples with post-
        // reconfiguration microphone samples. The independent source tracks
        // remain durable; only the in-flight canonical mix is resynchronised.
        acceptingSamples = false
        microphonePending.reset()
        systemPending.reset()
        logger.warning("Microphone input changed; rearming Meeting Mode capture")

        microphoneRecoveryTask = Task { @MainActor [weak self] in
            defer { self?.microphoneRecoveryTask = nil }
            do {
                // CoreAudio needs a short settling window after Meet changes
                // the default aggregate input device.
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isRunning else { return }
                self.microphoneSelection = try await self.startWorkingMicrophone(selection: selection)
                self.acceptingSamples = true
                self.logger.info("Microphone input re-armed for Meeting Mode")
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.microphoneRecoveryFailed = true
                // Keep system-audio capture alive so the session can still be
                // retained and uploaded with an honest source-gap status.
                self.acceptingSamples = true
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
            do {
                _ = try writer.append(samples, track: .system, sourceStartMs: Int64(systemSampleCount / 16))
                systemSampleCount += samples.count
                systemPending.append(samples)
                try mixAvailable()
            } catch {
                onFailure?(error)
            }
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

    private func mixAvailable(flushRemainder: Bool = false) throws {
        let available = min(microphonePending.count, systemPending.count)
        let count = flushRemainder ? available : (available / MeetingPCMChunkWriter.chunkSampleCount) * MeetingPCMChunkWriter.chunkSampleCount
        guard count > 0 else { return }
        let mic = microphonePending.drainPrefix(count)
        let system = systemPending.drainPrefix(count)
        let mixed = zip(mic, system).map { max(-1, min(1, ($0 + $1) * 0.5)) }
        _ = try writer.append(mixed, track: .mixed)
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
