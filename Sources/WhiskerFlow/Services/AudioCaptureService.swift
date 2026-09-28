@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Logging
import WhiskerFlowAppSupport
import WhiskerFlowObjCSupport

@MainActor
final class AVCaptureMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding {
    var authorizationState: MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .restricted
        }
    }

    func requestAccess() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume()
            }
        }
    }
}

enum AudioCaptureServiceError: LocalizedError {
    case deviceUnavailable
    case deviceAssignmentFailed(OSStatus)
    case invalidInputFormat
    case converterUnavailable
    case conversionFailed(String)
    /// Building the engine never finished: CoreAudio is stuck.
    case engineTimedOut

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "The selected microphone is no longer available."
        case .deviceAssignmentFailed(let status):
            return "The microphone could not be selected (CoreAudio \(status))."
        case .invalidInputFormat:
            return "The microphone reported an invalid audio format."
        case .converterUnavailable:
            return "The microphone audio format could not be converted."
        case .conversionFailed(let message):
            return "Microphone audio conversion failed: \(message)"
        case .engineTimedOut:
            return "macOS audio stopped responding. Quit and reopen WhiskerFlow to use the microphone."
        }
    }
}

enum CoreAudioDeviceCatalog {
    static func availableInputs() -> [AudioInputDescriptor] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap(descriptor).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func builtInInput() -> AudioInputDescriptor? {
        availableInputs().first { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device.transientID, &address, 0, nil, &size, &transport) == noErr && transport == kAudioDeviceTransportTypeBuiltIn
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func resolve(_ selection: AudioInputSelection) -> AudioInputDescriptor? {
        switch selection {
        case .systemDefault:
            guard let id = defaultInputDeviceID() else { return nil }
            return descriptor(id)
        case .device(let uid):
            // Translate the UID directly: a full catalog scan on every start
            // is avoidable main-actor CoreAudio work.
            guard let id = deviceID(forUID: uid),
                  let descriptor = descriptor(id), descriptor.uid == uid else { return nil }
            return descriptor
        }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &id
            )
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func descriptor(_ id: AudioDeviceID) -> AudioInputDescriptor? {
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
        return AudioInputDescriptor(uid: uid, name: name, transientID: id)
    }

    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        // CoreAudio hands back a +1 CFString for these properties.
        return value?.takeRetainedValue() as String?
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }
}

private final class AudioConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter?

    init(converter: AVAudioConverter?) {
        self.converter = converter
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

private final class ConversionFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// True only for the first failure of a capture, so the tap — which fires
    /// about ten times a second — can report at most once.
    @discardableResult
    func increment() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

private final class CaptureSampleCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func add(_ count: Int) { lock.withLock { storage += count } }
    func reset() { lock.withLock { storage = 0 } }
    var value: Int { lock.withLock { storage } }
}

final class OrdinaryAudioSpool: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private let buffer: BoundedAudioCaptureBuffer

    init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        file = output
        buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 16_000 * 30) { chunk in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: output.processingFormat,
                                             frameCapacity: AVAudioFrameCount(chunk.count)),
                  let channel = pcm.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            pcm.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: chunk.count) }
            }
            try output.write(from: pcm)
        }
    }

    func append(_ samples: [Float]) -> Bool { buffer.append(samples) }
    var totalSampleCount: Int { buffer.totalSampleCount }
    var failure: Error? { buffer.failure }
    var residentStartSample: Int { buffer.residentStartSample }
    func suffix(fromAbsoluteSample index: Int) -> [Float]? {
        buffer.residentSuffix(fromAbsoluteSample: index)
    }
    var residentSamples: [Float] { suffix(fromAbsoluteSample: residentStartSample) ?? [] }

    func discard() throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Where a tap sends converted audio for the capture that is running. Taps are
/// installed while an engine is prepared ahead of time, before its capture
/// exists, so each buffer looks up its destination here.
private final class CaptureSink: @unchecked Sendable {
    struct Session {
        let spool: OrdinaryAudioSpool?
        let store: LockedAudioBuffer
        let retainSamples: Bool
        let failures: ConversionFailureBox
        let sampleCount: CaptureSampleCountBox
        /// Tap callbacks received, converted or not; the stall watchdog's clock.
        let deliveredBuffers: CaptureSampleCountBox
        /// Converted samples, RMS level and peak for the main actor.
        let deliver: @Sendable ([Float], Float, Float) -> Void
        let reportFailure: @Sendable (Error, _ isFirst: Bool) -> Void
        let reportStorageFailure: @Sendable (Error) -> Void
    }

    private let lock = NSLock()
    private var session: Session?

    func begin(_ session: Session) { lock.withLock { self.session = session } }
    func end() { lock.withLock { session = nil } }
    var current: Session? { lock.withLock { session } }
}

/// An engine with its device assigned, tap installed and resources allocated,
/// but not started: no input I/O runs, so the microphone indicator stays off.
/// Building one costs roughly 100–150 ms, almost all of it off the hotkey path.
private final class PreparedCapture: @unchecked Sendable {
    let engine: AVAudioEngine
    let selection: AudioInputSelection
    let deviceID: AudioDeviceID
    let inputFormat: AVAudioFormat
    let sink: CaptureSink
    /// Installs the tap for `inputFormat`. Stopping a capture removes it, so a
    /// reused engine installs it again before starting.
    let installTap: () throws -> Void
    /// Touched only on the engine queue, or on the main actor while no engine
    /// queue work holds this capture.
    var tapInstalled = true

    init(engine: AVAudioEngine, selection: AudioInputSelection, deviceID: AudioDeviceID,
         inputFormat: AVAudioFormat, sink: CaptureSink, installTap: @escaping () throws -> Void) {
        self.engine = engine
        self.selection = selection
        self.deviceID = deviceID
        self.inputFormat = inputFormat
        self.sink = sink
        self.installTap = installTap
    }
}

/// The serial queue engines are built and torn down on. CoreAudio can keep an
/// engine's format query busy for seconds, or forever, after a device change.
/// A build that never returns has its queue abandoned for a fresh one, so later
/// captures are not queued behind it.
private final class CaptureEngineQueue: @unchecked Sendable {
    static let shared = CaptureEngineQueue()

    private let lock = NSLock()
    private var queue = CaptureEngineQueue.makeQueue()
    private var generation = 0

    var current: (queue: DispatchQueue, generation: Int) { lock.withLock { (queue, generation) } }

    func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    /// Returns false when that queue was already abandoned.
    @discardableResult
    func abandon(_ generation: Int) -> Bool {
        lock.withLock {
            guard self.generation == generation else { return false }
            self.generation += 1
            queue = Self.makeQueue()
            return true
        }
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "WhiskerFlow.capture-engine", qos: .userInitiated)
    }
}

/// Resumes a continuation exactly once, whichever of the work and its timeout
/// finishes first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}

@MainActor
final class AudioCaptureService {
    nonisolated private static let targetSampleRate = 16_000.0
    /// Builds and tears down engines away from the main actor.
    nonisolated private static var engineQueue: DispatchQueue { CaptureEngineQueue.shared.current.queue }
    /// A healthy build takes well under a second, and a few seconds while
    /// CoreAudio churns through a device change. Longer is a deadlock.
    nonisolated private static let engineBuildTimeoutSeconds = 6.0
    private static let timingLogger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AudioCapture"
    )
    private let samples = LockedAudioBuffer()
    private let capturedSampleCount = CaptureSampleCountBox()
    private let deliveredBufferCount = CaptureSampleCountBox()
    private var spool: OrdinaryAudioSpool?
    private let conversionFailures = ConversionFailureBox()
    private var active: PreparedCapture?
    /// Dictation and the meeting microphone each own an instance, so the stall
    /// sampler's "audio is live" set needs a per-instance key.
    private let captureActivitySource = "microphone-\(UUID().uuidString)"
    private var ready: PreparedCapture?
    /// Bumped by every stop, so a start still waiting for its engine knows it
    /// was superseded.
    private var startGeneration = 0
    private var readyObserver: NSObjectProtocol?
    private var readyGeneration = 0
    /// A background build for the next capture, until it becomes `ready` or a
    /// press claims it.
    private var preparation: Preparation?

    private struct Preparation {
        let selection: AudioInputSelection
        let generation: Int
        let task: Task<PreparedCapture?, Never>
    }
    private var configurationObserver: NSObjectProtocol?
    private var interruptionWatchdog: Task<Void, Never>?
    private var configurationObservationGate = AudioConfigurationObservationGate()

    /// Keep a prepared engine for the next capture. Dictation opts in; the
    /// meeting microphone starts rarely enough not to need one.
    var keepsCaptureReady = false
    /// Normalized 0...1 RMS level plus the buffer's absolute peak.
    var onLevel: ((Float, Float) -> Void)?
    /// Normalized 16 kHz mono samples for Meeting Mode's durable writer.
    var onSamples: (([Float]) -> Void)?
    var onConfigurationChange: (() -> Void)?
    /// The capture's recording file stopped accepting audio. Reported once per
    /// capture; audio captured before the failure is still returned by `stop`.
    /// When unset, a failure after some audio was kept ends the capture through
    /// `onConfigurationChange`, so recording stops where its audio does.
    var onStorageFailure: ((Error) -> Void)?

    func start(
        selection: AudioInputSelection,
        spoolTo audioURL: URL? = nil,
        retainSamples: Bool = true
    ) async throws {
        stopEngine()
        let generation = startGeneration
        samples.reset()
        capturedSampleCount.reset()
        deliveredBufferCount.reset()
        let ownSpool = try audioURL.map(OrdinaryAudioSpool.init)
        spool = ownSpool
        conversionFailures.reset()
        var started = false
        defer {
            if !started {
                try? ownSpool?.discard()
                if spool === ownSpool { spool = nil }
            }
        }

        guard let descriptor = CoreAudioDeviceCatalog.resolve(selection) else {
            throw AudioCaptureServiceError.deviceUnavailable
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        var prepared = takeReadyCapture(selection: selection, deviceID: descriptor.transientID)
        var enginePath = prepared == nil ? "built" : "ready"
        if prepared == nil, let inFlight = claimPreparation(selection: selection) {
            enginePath = "claimed"
            // A press soon after launch or a device change: use the engine
            // being built rather than queueing a second build behind it.
            prepared = await inFlight.value
            if let claimed = prepared, claimed.deviceID != descriptor.transientID {
                Self.retire(claimed)
                prepared = nil
            }
        }
        let capture: PreparedCapture
        do {
            do {
                capture = try await Self.makeCapture(
                    reusing: prepared, selection: selection, descriptor: descriptor)
            } catch AudioCaptureServiceError.engineTimedOut {
                // The stuck queue was abandoned; try once more on a fresh one.
                logger.error("Capture engine build timed out")
                capture = try await Self.makeCapture(
                    reusing: nil, selection: selection, descriptor: descriptor)
            }
        } catch AudioCaptureServiceError.deviceAssignmentFailed(let status) {
            logger.error(
                "Device assignment failed",
                metadata: ["core_audio.status": "\(status)"]
            )
            throw AudioCaptureServiceError.deviceAssignmentFailed(status)
        }
        if let prepared, capture !== prepared { enginePath = "rebuilt" }
        let engineReadyAt = ProcessInfo.processInfo.systemUptime
        guard generation == startGeneration else {
            // Stopped, or started again, while the engine was being built.
            Self.retire(capture)
            throw CancellationError()
        }

        // Observe before starting: a change posted while the engine starts
        // must not be missed.
        let observation = observeConfigurationChanges(for: capture.engine)
        capture.sink.begin(CaptureSink.Session(
            spool: spool,
            store: samples,
            retainSamples: retainSamples,
            failures: conversionFailures,
            sampleCount: capturedSampleCount,
            deliveredBuffers: deliveredBufferCount,
            deliver: { [weak self] converted, level, peak in
                // One main-actor hop per buffer carries both consumers.
                Task { @MainActor [weak self] in
                    self?.onSamples?(converted)
                    self?.onLevel?(level, peak)
                }
            },
            reportFailure: { [weak self] error, isFirstFailure in
                Task { @MainActor [weak self] in
                    self?.logger.error(
                        "Audio conversion failed",
                        metadata: ["error.code": "\((error as NSError).code)"]
                    )
                    // AppState reports the count when a capture yields nothing
                    // usable; this only marks that conversion started failing at
                    // all, so partial failures are not invisible.
                    if isFirstFailure {
                        DiagnosticsService.breadcrumb(
                            category: "audio",
                            metadata: ["error_code": "conversion_failed"]
                        )
                    }
                }
            },
            reportStorageFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.logger.error(
                        "Recording file stopped accepting audio",
                        metadata: ["error.code": "\((error as NSError).code)"]
                    )
                    DiagnosticsService.breadcrumb(
                        category: "audio",
                        metadata: ["error_code": "capture_storage_failed"]
                    )
                    self?.handleStorageFailure(error, generation: observation)
                }
            }
        ))

        do {
            try capture.engine.start()
            let now = ProcessInfo.processInfo.systemUptime
            Self.timingLogger.info("Capture engine started", metadata: [
                "event": "capture_start_timing",
                "engine_path": "\(enginePath)",
                "engine_ms": "\((engineReadyAt - startedAt) * 1000)",
                "engine_start_ms": "\((now - engineReadyAt) * 1000)",
                "elapsed_ms": "\((now - startedAt) * 1000)"
            ])
            active = capture
            Observability.setAudioCaptureActive(true, source: captureActivitySource)
            started = true
            startInterruptionWatchdog(for: capture.engine, generation: observation)
            logger.info(
                "Capture started",
                metadata: [
                    "audio.input.kind":
                        "\(selection.persistedValue == "system-default" ? "default" : "specific")"
                ]
            )
        } catch {
            stopObservingConfigurationChanges()
            capture.sink.end()
            Self.retire(capture)
            throw error
        }
    }

    /// Every format query and build waits on the engine's I/O unit queue, which
    /// CoreAudio can keep busy for seconds after a device change, so none of it
    /// may block the main actor. The engine queue also serializes builds with
    /// any preparation in flight.
    nonisolated private static func makeCapture(
        reusing prepared: PreparedCapture?,
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor
    ) async throws -> PreparedCapture {
        try await onEngineQueue(timeout: engineBuildTimeoutSeconds, discardLate: { retire($0) }) {
            if let prepared {
                if prepared.engine.inputNode.inputFormat(forBus: 0) == prepared.inputFormat {
                    if !prepared.tapInstalled {
                        try prepared.installTap()
                        prepared.tapInstalled = true
                        prepared.engine.prepare()
                    }
                    return prepared
                }
                prepared.engine.inputNode.removeTap(onBus: 0)
                prepared.engine.stop()
            }
            return try buildCapture(selection: selection, descriptor: descriptor)
        }
    }

    /// Prepares an engine for the next capture on `selection` in the background.
    func prepareCapture(for selection: AudioInputSelection) {
        guard keepsCaptureReady, active == nil else { return }
        if let ready, ready.selection == selection { return }
        if let preparation, preparation.selection == selection { return }
        discardReadyCapture()
        let generation = readyGeneration
        let task = Task.detached(priority: .userInitiated) { () -> PreparedCapture? in
            guard let descriptor = CoreAudioDeviceCatalog.resolve(selection) else { return nil }
            return try? await Self.onEngineQueue(
                timeout: Self.engineBuildTimeoutSeconds, discardLate: { Self.retire($0) }
            ) {
                try Self.buildCapture(selection: selection, descriptor: descriptor)
            }
        }
        preparation = Preparation(selection: selection, generation: generation, task: task)
        Task { @MainActor [weak self] in
            let capture = await task.value
            // Claimed by a press or discarded: that path owns the result.
            guard let self, self.preparation?.generation == generation else {
                if self == nil, let capture { Self.retire(capture) }
                return
            }
            self.preparation = nil
            guard let capture else { return }
            guard self.ready == nil, self.active == nil else {
                Self.retire(capture)
                return
            }
            self.adoptReadyCapture(capture)
        }
    }

    /// Takes over a matching build in flight; the caller owns its result.
    private func claimPreparation(selection: AudioInputSelection) -> Task<PreparedCapture?, Never>? {
        guard let preparation, preparation.selection == selection else { return nil }
        self.preparation = nil
        return preparation.task
    }

    /// The device list changed: a prepared engine may point at stale hardware.
    func invalidatePreparedCapture() {
        discardReadyCapture()
    }

    private func adoptReadyCapture(_ capture: PreparedCapture) {
        ready = capture
        readyObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: capture.engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.ready === capture else { return }
                // The hardware changed under the idle engine. Rebuild once the
                // change has settled, rather than querying it mid-change.
                let selection = capture.selection
                self.discardReadyCapture()
                let generation = self.readyGeneration
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.readyGeneration == generation else { return }
                self.prepareCapture(for: selection)
            }
        }
    }

    /// The prepared engine, if it still matches the device. The caller checks
    /// its format off the main actor.
    private func takeReadyCapture(selection: AudioInputSelection, deviceID: AudioDeviceID) -> PreparedCapture? {
        guard let ready else { return nil }
        guard ready.selection == selection, ready.deviceID == deviceID else {
            discardReadyCapture()
            return nil
        }
        removeReadyObserver()
        self.ready = nil
        readyGeneration &+= 1
        return ready
    }

    private func discardReadyCapture() {
        readyGeneration &+= 1
        if let preparation {
            self.preparation = nil
            Task { if let capture = await preparation.task.value { Self.retire(capture) } }
        }
        removeReadyObserver()
        if let ready { Self.retire(ready) }
        ready = nil
    }

    private func removeReadyObserver() {
        if let readyObserver {
            NotificationCenter.default.removeObserver(readyObserver)
            self.readyObserver = nil
        }
    }

    nonisolated private static func buildCapture(
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor
    ) throws -> PreparedCapture {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if case .device = selection {
            guard let audioUnit = inputNode.audioUnit else {
                throw AudioCaptureServiceError.deviceUnavailable
            }
            var id = descriptor.transientID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioCaptureServiceError.deviceAssignmentFailed(status)
            }
        }

        // The output format can still describe the previous default microphone
        // after a device switch. Install the tap with the assigned hardware format.
        let inputFormat = inputNode.inputFormat(forBus: 0)
        do {
            try AudioFormatValidator.validate(
                sampleRate: inputFormat.sampleRate,
                channelCount: inputFormat.channelCount
            )
        } catch {
            throw AudioCaptureServiceError.invalidInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw AudioCaptureServiceError.converterUnavailable }

        // Multichannel float input is mixed to mono in the tap; see `mixDown`.
        let mixFormat: AVAudioFormat? = inputFormat.channelCount > 1
            && inputFormat.commonFormat == .pcmFormatFloat32 && !inputFormat.isInterleaved
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                            channels: 1, interleaved: false)
            : nil
        let converterInput = mixFormat ?? inputFormat
        let converter: AVAudioConverter?
        if converterInput.sampleRate == targetFormat.sampleRate,
           converterInput.channelCount == targetFormat.channelCount,
           converterInput.commonFormat == targetFormat.commonFormat {
            converter = nil
        } else {
            converter = makeConverter(from: converterInput, to: targetFormat)
            guard converter != nil else { throw AudioCaptureServiceError.converterUnavailable }
        }
        let converterBox = AudioConverterBox(converter: converter)
        let sink = CaptureSink()

        // A call app reconfiguring the shared microphone can change the
        // hardware format after the query above; AVFAudio then raises an
        // Objective-C exception, which would abort the app. Fail this build
        // instead so the caller retries or falls back.
        let installTap = {
        var tapError: NSError?
        let tapInstalled = WFPerformCatchingObjCException({
        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { buffer, _ in
            guard let session = sink.current else { return }
            session.deliveredBuffers.add(1)
            do {
                let source = try mixFormat.map { try Self.mixDown(buffer, to: $0) } ?? buffer
                let converted = try Self.convert(
                    source,
                    converter: converterBox.converter,
                    targetFormat: targetFormat
                )
                if let spool = session.spool {
                    let alreadyFailed = spool.failure != nil
                    guard spool.append(converted) else {
                        // A failed spool stays failed; report the storage
                        // error once instead of ten times a second.
                        if !alreadyFailed {
                            session.reportStorageFailure(spool.failure ?? CocoaError(.fileWriteUnknown))
                        }
                        return
                    }
                } else if session.retainSamples {
                    session.store.append(converted)
                }
                session.sampleCount.add(converted.count)
                session.deliver(converted, Self.level(from: converted), Self.peak(from: converted))
            } catch {
                session.reportFailure(error, session.failures.increment())
            }
        }
        }, &tapError)
        guard tapInstalled else {
            Logging.Logger(label: "agency.thatworks.WhiskerFlow.AudioCapture")
                .error("Microphone tap rejected a changing input format", metadata: [
                "exception": "\(tapError?.userInfo["exceptionName"] ?? "unknown")"
            ])
            throw AudioCaptureServiceError.invalidInputFormat
        }
        }
        try installTap()
        engine.prepare()
        return PreparedCapture(
            engine: engine, selection: selection, deviceID: descriptor.transientID,
            inputFormat: inputFormat, sink: sink, installTap: installTap
        )
    }

    /// Without `downmix`, AVAudioConverter keeps only channel 0 of a
    /// multichannel input. `downmix` only helps layouts it understands, so
    /// the tap mixes float input itself and this covers other formats.
    nonisolated static func makeConverter(
        from inputFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if inputFormat.channelCount > targetFormat.channelCount {
            converter?.downmix = true
        }
        return converter
    }

    /// Channels quieter than this (-60 dBFS) are idle inputs, not a mic.
    nonisolated static let mixDownNoiseFloorRMS: Float = 0.001
    /// Channels more than 12 dB below the loudest are left out of the mix.
    nonisolated static let mixDownRelativeFloor: Float = 0.25

    /// Mixes deinterleaved float input to mono by averaging only the channels
    /// that carry signal, so a mic on any input keeps its full level instead
    /// of being diluted by idle channels. The converter's `downmix` outputs
    /// silence for the discrete layouts that interfaces and aggregate devices
    /// report, losing a mic on any input but the first.
    nonisolated static func mixDown(
        _ input: AVAudioPCMBuffer,
        to monoFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frames = input.frameLength
        let channelCount = Int(input.format.channelCount)
        guard let source = input.floatChannelData, !input.format.isInterleaved,
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(frames, 1)),
              let destination = output.floatChannelData?[0]
        else { throw AudioCaptureServiceError.converterUnavailable }
        output.frameLength = frames
        guard frames > 0 else { return output }
        let count = vDSP_Length(frames)
        let levels = (0..<channelCount).map { channel -> Float in
            var rms: Float = 0
            vDSP_rmsqv(source[channel], 1, &rms, count)
            return rms
        }
        let loudest = levels.indices.max { levels[$0] < levels[$1] } ?? 0
        let floor = max(mixDownNoiseFloorRMS, levels[loudest] * mixDownRelativeFloor)
        let active = levels.indices.filter { $0 != loudest && levels[$0] >= floor }
        destination.update(from: source[loudest], count: Int(frames))
        guard !active.isEmpty else { return output }
        for channel in active {
            vDSP_vadd(destination, 1, source[channel], 1, destination, 1, count)
        }
        var scale = 1 / Float(active.count + 1)
        vDSP_vsmul(destination, 1, &scale, destination, 1, count)
        return output
    }

    /// Runs `work` on the engine queue. Past `timeout` the queue is abandoned
    /// and this throws `engineTimedOut`; a result that arrives later goes to
    /// `discardLate`.
    nonisolated private static func onEngineQueue<T: Sendable>(
        timeout: Double,
        discardLate: @escaping @Sendable (T) -> Void,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let engineQueue = CaptureEngineQueue.shared.current
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            engineQueue.queue.async {
                // Queued behind a build that wedged: running now would
                // instantiate a unit next to the replacement queue's.
                guard CaptureEngineQueue.shared.isCurrent(engineQueue.generation) else {
                    once.resume(with: .failure(CancellationError()))
                    return
                }
                let result = Result { try work() }
                if !once.resume(with: result), case .success(let late) = result { discardLate(late) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.resume(with: .failure(AudioCaptureServiceError.engineTimedOut)) {
                    CaptureEngineQueue.shared.abandon(engineQueue.generation)
                    Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
                        .error("Capture engine build timed out", metadata: ["event": "capture_engine_timeout"])
                }
            }
        }
    }

    /// Engine teardown and deallocation take ~10–15 ms; keep them off the caller.
    nonisolated private static func retire(_ capture: PreparedCapture) {
        engineQueue.async {
            capture.engine.inputNode.removeTap(onBus: 0)
            capture.engine.stop()
        }
    }

    func sampleCount() -> Int {
        capturedSampleCount.value
    }

    func snapshotTail(from index: Int) -> [Float] {
        spool?.suffix(fromAbsoluteSample: index) ?? samples.suffix(from: index)
    }

    func hasResidentSamples(from index: Int) -> Bool {
        guard let spool else { return true }
        return index >= spool.residentStartSample
    }

    func stop(reason: CaptureStopReason) -> CapturedAudio {
        stopEngine(reusable: reason == .userReleased)
        onLevel?(0, 0)
        var completedSpool = spool
        spool = nil
        let storageFailed = completedSpool?.failure != nil
        if storageFailed, completedSpool?.totalSampleCount == 0 {
            // Nothing reached the file. Until callers can tell a storage
            // failure apart, a non-zero failure count keeps this from being
            // dismissed as silence.
            try? completedSpool?.discard()
            return CapturedAudio(
                samples: [], stopReason: reason,
                conversionFailureCount: max(1, conversionFailures.value),
                storageFailed: true
            )
        }
        // After a write failure the file still holds every sample before it,
        // and its header is finalized on release like any other capture.
        let residentSamples = completedSpool?.residentSamples ?? samples.drain()
        let audioURL = completedSpool?.url
        let totalSampleCount = completedSpool?.totalSampleCount
        let residentStartSample = completedSpool?.residentStartSample ?? 0
        // AVAudioFile finalizes its container header when released. Do that
        // before callers reopen the URL for bounded transcription.
        completedSpool = nil
        return CapturedAudio(
            samples: residentSamples,
            stopReason: reason,
            conversionFailureCount: conversionFailures.value,
            audioURL: audioURL,
            totalSampleCount: totalSampleCount,
            residentStartSample: residentStartSample,
            storageFailed: storageFailed
        )
    }

    func cancel() {
        stopEngine()
        samples.reset()
        try? spool?.discard()
        spool = nil
        conversionFailures.reset()
        capturedSampleCount.reset()
        deliveredBufferCount.reset()
        onLevel?(0, 0)
    }

    /// `reusable`: the capture ended normally, so its engine can serve the next
    /// one and only a device change costs a build.
    private func stopEngine(reusable: Bool = false) {
        startGeneration &+= 1
        stopObservingConfigurationChanges()
        guard let active else { return }
        self.active = nil
        Observability.setAudioCaptureActive(false, source: captureActivitySource)
        // Stop synchronously so every delivered buffer is in the spool before the
        // caller reads it; only deallocation is deferred.
        active.engine.inputNode.removeTap(onBus: 0)
        active.tapInstalled = false
        active.engine.stop()
        active.sink.end()
        if reusable, keepsCaptureReady, ready == nil {
            adoptReadyCapture(active)
        } else {
            Self.engineQueue.async { _ = active }
        }
    }

    /// AVAudioEngine stops itself when a hardware change really affects it,
    /// and absorbs the changes it posts while building its device aggregate.
    /// Acting on the engine's running state — not on a fixed startup delay —
    /// holds on slow Macs whose startup changes arrive late, and never leaves
    /// a stopped engine recording silence.
    private func observeConfigurationChanges(for engine: AVAudioEngine) -> UInt64 {
        stopObservingConfigurationChanges()
        let generation = configurationObservationGate.captureStarted()
        _ = configurationObservationGate.arm(generation)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.active?.engine === engine,
                      self.configurationObservationGate.shouldHandleChange(for: generation),
                      CaptureInterruptionDetector.configurationChangeInterrupts(
                          engineIsRunning: engine.isRunning
                      )
                else { return }
                self.reportInterruption(generation, cause: "configuration_change")
            }
        }
        return generation
    }

    /// Catches an engine that stops without a notification we saw, and a tap
    /// that stops firing while the engine still claims to run.
    private func startInterruptionWatchdog(for engine: AVAudioEngine, generation: UInt64) {
        interruptionWatchdog?.cancel()
        interruptionWatchdog = Task { @MainActor [weak self] in
            var detector = CaptureInterruptionDetector()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.active?.engine === engine,
                      self.configurationObservationGate.shouldHandleChange(for: generation)
                else { return }
                let running = engine.isRunning
                if detector.isInterrupted(
                    deliveredBufferCount: self.deliveredBufferCount.value,
                    engineIsRunning: running,
                    now: ProcessInfo.processInfo.systemUptime
                ) {
                    self.reportInterruption(generation, cause: running ? "buffers_stalled" : "engine_stopped")
                    return
                }
            }
        }
    }

    private func handleStorageFailure(_ error: Error, generation: UInt64) {
        guard configurationObservationGate.shouldHandleChange(for: generation) else { return }
        if let onStorageFailure {
            onStorageFailure(error)
        } else if capturedSampleCount.value > 0 {
            // Nothing past this point is kept. End the capture as a lost
            // microphone would, so the user learns the transcript is partial
            // instead of speaking into a recording that no longer grows.
            reportInterruption(generation, cause: "storage_failed")
        }
    }

    private func reportInterruption(_ generation: UInt64, cause: String) {
        guard configurationObservationGate.claimInterruption(for: generation) else { return }
        logger.warning("Capture interrupted", metadata: ["cause": "\(cause)"])
        onConfigurationChange?()
    }

    private func stopObservingConfigurationChanges() {
        interruptionWatchdog?.cancel()
        interruptionWatchdog = nil
        configurationObservationGate.captureStopped()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    nonisolated private static func convert(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) throws -> [Float] {
        let output: AVAudioPCMBuffer
        if let converter {
            let ratio = targetFormat.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw AudioCaptureServiceError.converterUnavailable
            }
            let inputBox = ConverterInputBox(buffer: input)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                inputBox.next(inputStatus)
            }
            guard status != .error, conversionError == nil else {
                throw AudioCaptureServiceError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown error"
                )
            }
            output = converted
        } else {
            output = input
        }

        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    nonisolated private static func level(from buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        let db = 20 * log10(max(rms, 1e-7))
        return (max(-50, min(0, db)) + 50) / 50
    }

    nonisolated private static func peak(from buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(buffer, 1, &peak, vDSP_Length(buffer.count))
        return peak
    }
}

enum AudioFileWriter {
    static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    static func makeRecordingURL() throws -> URL {
        guard let folder = recordingsDirectoryURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(UUID().uuidString).wav")
    }

    static func recordingsDirectoryURL() -> URL? {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return root.appendingPathComponent("WhiskerFlow/Recordings", isDirectory: true)
    }
}
