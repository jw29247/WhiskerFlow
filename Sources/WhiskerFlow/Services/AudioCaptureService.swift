@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Logging
import WhiskerFlowAppSupport

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
            return availableInputs().first { $0.uid == uid }
        }
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
        return value?.takeUnretainedValue() as String?
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
        /// Converted samples, RMS level and peak for the main actor.
        let deliver: @Sendable ([Float], Float, Float) -> Void
        let reportFailure: @Sendable (Error, _ isFirst: Bool) -> Void
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
    /// What was requested, so a changed preference rebuilds the engine even if
    /// the device refused voice processing and this engine fell back.
    let requestedVoiceProcessing: Bool

    init(engine: AVAudioEngine, selection: AudioInputSelection, deviceID: AudioDeviceID,
         inputFormat: AVAudioFormat, sink: CaptureSink, requestedVoiceProcessing: Bool) {
        self.engine = engine
        self.selection = selection
        self.deviceID = deviceID
        self.inputFormat = inputFormat
        self.sink = sink
        self.requestedVoiceProcessing = requestedVoiceProcessing
    }
}

@MainActor
final class AudioCaptureService {
    nonisolated private static let targetSampleRate = 16_000.0
    /// Builds and tears down engines away from the main actor.
    nonisolated private static let engineQueue = DispatchQueue(label: "WhiskerFlow.capture-engine", qos: .userInitiated)
    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AudioCapture"
    )
    private let samples = LockedAudioBuffer()
    private let capturedSampleCount = CaptureSampleCountBox()
    private var spool: OrdinaryAudioSpool?
    private let conversionFailures = ConversionFailureBox()
    private var active: PreparedCapture?
    private var ready: PreparedCapture?
    private var readyObserver: NSObjectProtocol?
    private var readyGeneration = 0
    private var configurationObserver: NSObjectProtocol?
    private var configurationArmTask: Task<Void, Never>?
    private var configurationObservationGate = AudioConfigurationObservationGate()

    /// Keep a prepared engine for the next capture. Dictation opts in; the
    /// meeting microphone starts rarely enough not to need one.
    var keepsCaptureReady = false
    /// Apple voice processing: cancels what this Mac plays through its speakers
    /// (videos, calls) out of the microphone signal, and makes the system Mic
    /// Mode (e.g. Voice Isolation, which suppresses other voices) available.
    /// Applies to engines built after it changes.
    var voiceProcessing = false
    /// Normalized 0...1 RMS level plus the buffer's absolute peak.
    var onLevel: ((Float, Float) -> Void)?
    /// Normalized 16 kHz mono samples for Meeting Mode's durable writer.
    var onSamples: (([Float]) -> Void)?
    var onConfigurationChange: (() -> Void)?

    func start(
        selection: AudioInputSelection,
        spoolTo audioURL: URL? = nil,
        retainSamples: Bool = true
    ) throws {
        stopEngine()
        samples.reset()
        capturedSampleCount.reset()
        spool = try audioURL.map(OrdinaryAudioSpool.init)
        conversionFailures.reset()
        var started = false
        defer {
            if !started {
                try? spool?.discard()
                spool = nil
            }
        }

        guard let descriptor = CoreAudioDeviceCatalog.resolve(selection) else {
            throw AudioCaptureServiceError.deviceUnavailable
        }

        let capture: PreparedCapture
        if let prepared = takeReadyCapture(selection: selection, deviceID: descriptor.transientID) {
            capture = prepared
        } else {
            do {
                capture = try Self.buildCapture(
                    selection: selection, descriptor: descriptor, voiceProcessing: voiceProcessing)
            } catch AudioCaptureServiceError.deviceAssignmentFailed(let status) {
                logger.error(
                    "Device assignment failed",
                    metadata: ["core_audio.status": "\(status)"]
                )
                throw AudioCaptureServiceError.deviceAssignmentFailed(status)
            }
        }

        capture.sink.begin(CaptureSink.Session(
            spool: spool,
            store: samples,
            retainSamples: retainSamples,
            failures: conversionFailures,
            sampleCount: capturedSampleCount,
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
            }
        ))

        do {
            try capture.engine.start()
            active = capture
            started = true
            armConfigurationObservation(for: capture.engine)
            logger.info(
                "Capture started",
                metadata: [
                    "audio.input.kind":
                        "\(selection.persistedValue == "system-default" ? "default" : "specific")"
                ]
            )
        } catch {
            capture.sink.end()
            Self.retire(capture)
            throw error
        }
    }

    /// Prepares an engine for the next capture on `selection` in the background.
    func prepareCapture(for selection: AudioInputSelection) {
        guard keepsCaptureReady, active == nil else { return }
        if let ready, ready.selection == selection, ready.requestedVoiceProcessing == voiceProcessing { return }
        discardReadyCapture()
        let generation = readyGeneration
        let voiceProcessing = voiceProcessing
        Self.engineQueue.async { [weak self] in
            guard let descriptor = CoreAudioDeviceCatalog.resolve(selection),
                  let capture = try? Self.buildCapture(
                    selection: selection, descriptor: descriptor, voiceProcessing: voiceProcessing)
            else { return }
            Task { @MainActor [weak self] in
                // A press that raced this preparation built its own engine;
                // the next one is prepared once that capture ends.
                guard let self, self.readyGeneration == generation, self.ready == nil,
                      self.active == nil else {
                    Self.retire(capture)
                    return
                }
                self.adoptReadyCapture(capture)
            }
        }
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
                // The hardware changed under the idle engine; rebuild it lazily.
                let selection = capture.selection
                self.discardReadyCapture()
                self.prepareCapture(for: selection)
            }
        }
    }

    /// The prepared engine, if it still matches the device and its format.
    private func takeReadyCapture(selection: AudioInputSelection, deviceID: AudioDeviceID) -> PreparedCapture? {
        guard let ready else { return nil }
        guard ready.selection == selection, ready.deviceID == deviceID,
              ready.requestedVoiceProcessing == voiceProcessing,
              ready.engine.inputNode.inputFormat(forBus: 0) == ready.inputFormat else {
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

    /// Voice processing is best effort: a device or route that refuses it still
    /// records, just without echo cancellation.
    nonisolated private static func buildCapture(
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor,
        voiceProcessing: Bool
    ) throws -> PreparedCapture {
        guard voiceProcessing else {
            return try buildCapture(selection: selection, descriptor: descriptor,
                                    enableVoiceProcessing: false, requested: false)
        }
        do {
            return try buildCapture(selection: selection, descriptor: descriptor,
                                    enableVoiceProcessing: true, requested: true)
        } catch {
            return try buildCapture(selection: selection, descriptor: descriptor,
                                    enableVoiceProcessing: false, requested: true)
        }
    }

    nonisolated private static func buildCapture(
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor,
        enableVoiceProcessing: Bool,
        requested: Bool
    ) throws -> PreparedCapture {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if enableVoiceProcessing {
            // Must precede device assignment and the format query: it swaps the
            // node's I/O unit for the voice-processing unit.
            try inputNode.setVoiceProcessingEnabled(true)
            // Dictation must not turn down the video or call the user is playing.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
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

        // The voice-processing unit reports every hardware channel (9 on a
        // MacBook Pro array) but carries the processed voice on the first;
        // downmixing would blend it with the unprocessed channels.
        let usesFirstChannel = enableVoiceProcessing && inputFormat.channelCount > 1
        let converterInput: AVAudioFormat
        if usesFirstChannel {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                           channels: 1, interleaved: false) else {
                throw AudioCaptureServiceError.converterUnavailable
            }
            converterInput = mono
        } else {
            converterInput = inputFormat
        }
        let converter: AVAudioConverter?
        if converterInput.sampleRate == targetFormat.sampleRate,
           converterInput.channelCount == targetFormat.channelCount,
           converterInput.commonFormat == targetFormat.commonFormat {
            converter = nil
        } else {
            converter = AVAudioConverter(from: converterInput, to: targetFormat)
            guard converter != nil else { throw AudioCaptureServiceError.converterUnavailable }
        }
        let converterBox = AudioConverterBox(converter: converter)
        let sink = CaptureSink()

        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { buffer, _ in
            guard let session = sink.current else { return }
            do {
                let source = usesFirstChannel ? try Self.firstChannel(of: buffer, format: converterInput) : buffer
                let converted = try Self.convert(
                    source,
                    converter: converterBox.converter,
                    targetFormat: targetFormat
                )
                if let spool = session.spool {
                    guard spool.append(converted) else { throw spool.failure ?? CocoaError(.fileWriteUnknown) }
                } else if session.retainSamples {
                    session.store.append(converted)
                }
                session.sampleCount.add(converted.count)
                session.deliver(converted, Self.level(from: converted), Self.peak(from: converted))
            } catch {
                session.reportFailure(error, session.failures.increment())
            }
        }
        engine.prepare()
        return PreparedCapture(
            engine: engine, selection: selection, deviceID: descriptor.transientID,
            inputFormat: inputFormat, sink: sink, requestedVoiceProcessing: requested
        )
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
        stopEngine()
        onLevel?(0, 0)
        var completedSpool = spool
        spool = nil
        if completedSpool?.failure != nil {
            try? completedSpool?.discard()
            return CapturedAudio(
                samples: [], stopReason: reason,
                conversionFailureCount: max(1, conversionFailures.value)
            )
        }
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
            residentStartSample: residentStartSample
        )
    }

    func cancel() {
        stopEngine()
        samples.reset()
        try? spool?.discard()
        spool = nil
        conversionFailures.reset()
        capturedSampleCount.reset()
        onLevel?(0, 0)
    }

    private func stopEngine() {
        configurationArmTask?.cancel()
        configurationArmTask = nil
        configurationObservationGate.captureStopped()
        removeConfigurationObserver()
        guard let active else { return }
        self.active = nil
        // Stop synchronously so every delivered buffer is in the spool before the
        // caller reads it; only deallocation is deferred.
        active.engine.inputNode.removeTap(onBus: 0)
        active.engine.stop()
        active.sink.end()
        Self.engineQueue.async { _ = active }
    }

    private func armConfigurationObservation(for engine: AVAudioEngine) {
        let generation = configurationObservationGate.captureStarted()
        configurationArmTask?.cancel()
        configurationArmTask = Task { @MainActor [weak self] in
            // AVAudioEngine emits configuration changes while constructing its
            // default-device aggregate. Those are startup mechanics, not a hot-plug.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.active?.engine === engine,
                  self.configurationObservationGate.arm(generation) else { return }

            self.configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.configurationObservationGate.shouldHandleChange(for: generation)
                    else { return }
                    self.onConfigurationChange?()
                }
            }
            self.configurationArmTask = nil
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    nonisolated private static func firstChannel(of buffer: AVAudioPCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, buffer.frameLength)),
              let destination = mono.floatChannelData?[0] else {
            throw AudioCaptureServiceError.conversionFailed("voice-processed channel unavailable")
        }
        mono.frameLength = buffer.frameLength
        // Interleaved data strides across channels; non-interleaved has stride 1.
        let stride = buffer.stride
        for frame in 0..<Int(buffer.frameLength) { destination[frame] = source[frame * stride] }
        return mono
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
