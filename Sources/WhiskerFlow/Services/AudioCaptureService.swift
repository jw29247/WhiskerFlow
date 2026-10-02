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
        defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Whether an idle capture unit for `deviceID` may be kept ready; see
    /// `CaptureReadinessPolicy`. The default output no longer matters: the
    /// input-only unit never opens it.
    static func keepsEngineReady(for deviceID: AudioDeviceID, selection: AudioInputSelection) -> Bool {
        func traits(_ id: AudioDeviceID?) -> AudioDeviceTraits? {
            id.map { AudioDeviceTraits(transport: transport(of: $0), name: name(of: $0)) }
        }
        guard let selected = traits(deviceID) else { return false }
        let followsDefault = selection == .systemDefault
        return CaptureReadinessPolicy.keepsEngineReady(
            selected: selected,
            defaultInput: followsDefault ? traits(defaultInputDeviceID()) : nil,
            followsSystemDefault: followsDefault)
    }

    /// The device values a capture unit depends on, read now.
    static func captureState(of id: AudioDeviceID) -> CaptureDeviceState {
        var alive: UInt32 = 0
        let isAlive = scalarProperty(id, selector: kAudioDevicePropertyDeviceIsAlive, value: &alive) && alive != 0
        var rate = Float64(0)
        let hasRate = scalarProperty(id, selector: kAudioDevicePropertyNominalSampleRate, value: &rate)
        return CaptureDeviceState(
            isAlive: isAlive,
            nominalSampleRate: hasRate && rate > 0 ? rate : nil,
            inputChannelCount: knownInputChannelCount(id),
            defaultInputDeviceID: defaultInputDeviceID()
        )
    }

    /// The top of the device's I/O buffer size range: the most frames one
    /// input callback can carry.
    static func bufferFrameSizeLimit(of id: AudioDeviceID) -> Int? {
        var range = AudioValueRange()
        guard scalarProperty(id, selector: kAudioDevicePropertyBufferFrameSizeRange, value: &range),
              range.mMaximum.isFinite, range.mMaximum > 0 else { return nil }
        return Int(range.mMaximum)
    }

    private static func scalarProperty<T>(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        } == noErr
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    /// The device's display name, or an empty string.
    static func name(of id: AudioDeviceID) -> String { descriptor(id)?.name ?? "" }

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
        knownInputChannelCount(id) ?? 0
    }

    /// Input channels across all input streams, or nil if CoreAudio can't say.
    private static func knownInputChannelCount(_ id: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else {
            return nil
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

/// Where a capture unit sends converted audio for the capture that is running.
/// Units are prepared ahead of time, before their capture exists, and reused
/// across captures, so each buffer looks up its destination here.
private final class CaptureSink: @unchecked Sendable {
    struct Session {
        let spool: OrdinaryAudioSpool?
        let store: LockedAudioBuffer
        let retainSamples: Bool
        let failures: ConversionFailureBox
        let sampleCount: CaptureSampleCountBox
        /// Chunks processed, converted or not; the stall watchdog's clock.
        let deliveredBuffers: CaptureSampleCountBox
        /// Input callbacks whose render failed.
        let renderFailures: CaptureSampleCountBox
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

/// The HAL unit's input callback. It runs on CoreAudio's real-time I/O
/// thread, so it only renders into preallocated buffers and copies them into
/// the ring; conversion, files and the main actor are the processing queue's.
private let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<HALInputContext>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}

/// Tracks whether the unit really runs, for the interruption watchdog.
private let halRunningListener: AudioUnitPropertyListenerProc = { refCon, unit, _, _, _ in
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioUnitGetProperty(
        unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size
    ) == noErr else { return }
    Unmanaged<HALInputContext>.fromOpaque(refCon).takeUnretainedValue().setRunning(running != 0)
}

/// What the input callback touches. The unit holds an unretained pointer to
/// it, so its PreparedCapture disposes the unit before releasing it.
private final class HALInputContext: @unchecked Sendable {
    let unit: AudioUnit
    let ring: PlanarAudioRingBuffer
    private let capacityFrames: Int
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let channelData: [UnsafeMutablePointer<Float>]
    private let runningLock = NSLock()
    private var running = false

    init(unit: AudioUnit, plan: HALInputCapturePlan) {
        self.unit = unit
        ring = PlanarAudioRingBuffer(channelCount: plan.channelCount, capacityFrames: plan.ringCapacityFrames)
        capacityFrames = plan.renderCapacityFrames
        bufferList = AudioBufferList.allocate(maximumBuffers: plan.channelCount)
        channelData = (0..<plan.channelCount).map { _ in
            let data = UnsafeMutablePointer<Float>.allocate(capacity: plan.renderCapacityFrames)
            data.initialize(repeating: 0, count: plan.renderCapacityFrames)
            return data
        }
    }

    deinit {
        channelData.forEach { $0.deallocate() }
        free(bufferList.unsafeMutablePointer)
    }

    var isRunning: Bool { runningLock.withLock { running } }
    func setRunning(_ value: Bool) { runningLock.withLock { running = value } }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        let count = Int(frames)
        guard count <= capacityFrames else {
            ring.recordRenderFailure(kAudioUnitErr_TooManyFramesToProcess)
            return noErr
        }
        // Render resets sizes, and may swap in its own buffers; restore ours.
        let byteSize = UInt32(count * MemoryLayout<Float>.size)
        for index in channelData.indices {
            bufferList[index] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(channelData[index]))
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            ring.recordRenderFailure(status)
            return noErr
        }
        let list = bufferList
        let own = channelData
        ring.write(frames: count) { channel in
            UnsafePointer(list[channel].mData?.assumingMemoryBound(to: Float.self) ?? own[channel])
        }
        return noErr
    }
}

/// Turns what the input callback buffered into the 16 kHz mono samples the
/// rest of the app takes: ~100 ms chunks at the device's rate, mixed down and
/// converted as the engine tap's buffers were. Used only on its capture's
/// processing queue (or by tests).
final class CaptureChunkProcessor: @unchecked Sendable {
    let plan: HALInputCapturePlan
    let ring: PlanarAudioRingBuffer
    private let chunk: AVAudioPCMBuffer
    private let mixFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    init(plan: HALInputCapturePlan, ring: PlanarAudioRingBuffer, targetSampleRate: Double) throws {
        guard let deviceFormat = Self.deviceFormat(for: plan),
              let chunk = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: AVAudioFrameCount(plan.chunkFrames))
        else { throw AudioCaptureServiceError.invalidInputFormat }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false
        ) else { throw AudioCaptureServiceError.converterUnavailable }
        // Multichannel input is mixed to mono first; see `mixDown`.
        let mixFormat = plan.needsMixDown
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: plan.sampleRate, channels: 1, interleaved: false)
            : nil
        if plan.needsMixDown, mixFormat == nil { throw AudioCaptureServiceError.converterUnavailable }
        let converter: AVAudioConverter?
        if plan.needsResampling(to: targetSampleRate) {
            converter = AudioCaptureService.makeConverter(from: mixFormat ?? deviceFormat, to: targetFormat)
            guard converter != nil else { throw AudioCaptureServiceError.converterUnavailable }
        } else {
            converter = nil
        }
        self.plan = plan
        self.ring = ring
        self.chunk = chunk
        self.mixFormat = mixFormat
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// Float, deinterleaved; AVAudioFormat needs a layout past two channels.
    static func deviceFormat(for plan: HALInputCapturePlan) -> AVAudioFormat? {
        if plan.channelCount <= 2 {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: plan.sampleRate,
                channels: AVAudioChannelCount(plan.channelCount), interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(plan.channelCount)
        ) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: plan.sampleRate, channelLayout: layout)
    }

    /// A new capture starts without the last one's resampler history.
    func reset() { converter?.reset() }

    /// Converts every full chunk buffered, and with `final` the remainder too,
    /// handing each result to `body` in order.
    func drain(final: Bool, _ body: (Result<[Float], Error>) -> Void) {
        guard let channels = chunk.floatChannelData else { return }
        while ring.availableFrames >= plan.chunkFrames || (final && ring.availableFrames > 0) {
            let frames = ring.read(into: channels, maxFrames: plan.chunkFrames)
            guard frames > 0 else { return }
            chunk.frameLength = AVAudioFrameCount(frames)
            body(Result {
                let source = try mixFormat.map { try AudioCaptureService.mixDown(chunk, to: $0) } ?? chunk
                return try AudioCaptureService.convert(source, converter: converter, targetFormat: targetFormat)
            })
        }
    }

    /// Empties the ring without converting, when no capture wants the audio.
    func discardBuffered() {
        guard let channels = chunk.floatChannelData else { return }
        while ring.read(into: channels, maxFrames: plan.chunkFrames) > 0 {}
    }
}

/// CoreAudio property listeners on a capture's device, and on the system
/// default input for a system-default capture. Values are read and compared
/// on the listener queue, never on the main actor; only a real change
/// reaches the handler.
private final class CaptureDeviceObserver: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "WhiskerFlow.capture-device-listener", qos: .userInitiated)

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    let expectation: CaptureDeviceExpectation
    private let lock = NSLock()
    private var handler: (@Sendable (CaptureDeviceChange) -> Void)?
    /// Engine queue only.
    private var registrations: [Registration] = []

    init(expectation: CaptureDeviceExpectation) {
        self.expectation = expectation
    }

    func setHandler(_ handler: (@Sendable (CaptureDeviceChange) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func register() {
        let device = AudioObjectID(expectation.deviceID)
        add(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
        add(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
        add(device, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        add(device, kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput)
        if expectation.followsSystemDefault {
            add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                kAudioObjectPropertyScopeGlobal)
        }
    }

    func unregister() {
        setHandler(nil)
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, Self.queue, registration.block)
        }
        registrations.removeAll()
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, Self.queue, block) == noErr else { return }
        registrations.append(Registration(object: object, address: address, block: block))
    }

    private func evaluate() {
        let state = CoreAudioDeviceCatalog.captureState(of: AudioDeviceID(expectation.deviceID))
        guard let change = expectation.change(in: state) else { return }
        lock.withLock { handler }?(change)
    }
}

/// An input-only HAL unit with its device assigned, formats set and resources
/// allocated (`AudioUnitInitialize`), but not started: no input I/O runs, so
/// the microphone indicator stays off. Its output side is disabled, so unlike
/// AVAudioEngine it never opens the default output or builds an aggregate of
/// the default devices, and only the given microphone is ever touched. A
/// capture that stops normally stays initialized for the next press.
private final class PreparedCapture: @unchecked Sendable {
    let selection: AudioInputSelection
    let deviceID: AudioDeviceID
    let context: HALInputContext
    let processor: CaptureChunkProcessor
    let observer: CaptureDeviceObserver
    let sink = CaptureSink()
    private let processingQueue = DispatchQueue(label: "WhiskerFlow.capture-processing", qos: .userInitiated)
    /// Main actor only.
    private var drainTimer: DispatchSourceTimer?
    /// Processing queue only.
    private var reportedRenderFailure = false
    private var reportedDrops = false
    private let disposeLock = NSLock()
    private var disposed = false

    var unit: AudioUnit { context.unit }
    var expectation: CaptureDeviceExpectation { observer.expectation }

    init(selection: AudioInputSelection, deviceID: AudioDeviceID, expectation: CaptureDeviceExpectation,
         context: HALInputContext, processor: CaptureChunkProcessor) {
        self.selection = selection
        self.deviceID = deviceID
        self.context = context
        self.processor = processor
        observer = CaptureDeviceObserver(expectation: expectation)
    }

    deinit {
        drainTimer?.cancel()
        dispose()
    }

    /// Before the unit starts: an empty ring and a timer that converts what
    /// arrives every 50 ms, so the pipeline still sees ~100 ms buffers.
    func beginDelivery() {
        context.ring.reopen()
        processingQueue.sync {
            processor.reset()
            reportedRenderFailure = false
            reportedDrops = false
        }
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain(final: false) }
        timer.resume()
        drainTimer = timer
    }

    /// Closes the ring, so the callback adds nothing more, and delivers what
    /// it holds before returning: the spool is complete when the caller reads
    /// it, without waiting on CoreAudio to stop the unit.
    func finishDelivery() {
        context.ring.close()
        drainTimer?.cancel()
        drainTimer = nil
        processingQueue.sync { drain(final: true) }
    }

    private func drain(final: Bool) {
        guard let session = sink.current else {
            processor.discardBuffered()
            return
        }
        let trouble = context.ring.takeTrouble()
        if trouble.renderFailures > 0 {
            // Counted apart from conversion failures: a few while the device
            // settles must not stop a short or silent capture being discarded.
            session.renderFailures.add(trouble.renderFailures)
            if !reportedRenderFailure {
                reportedRenderFailure = true
                Logging.Logger(label: "agency.thatworks.WhiskerFlow.AudioCapture")
                    .error("Microphone render failed", metadata: [
                        "core_audio.status": "\(trouble.lastRenderStatus)"
                    ])
            }
        }
        if trouble.droppedFrames > 0, !reportedDrops {
            reportedDrops = true
            Logging.Logger(label: "agency.thatworks.WhiskerFlow.AudioCapture")
                .warning("Capture processing fell behind; audio dropped", metadata: [
                    "frames": "\(trouble.droppedFrames)"
                ])
        }
        processor.drain(final: final) { AudioCaptureService.deliver($0, to: session) }
    }

    /// Engine queue. Idempotent; also the deinit safety net.
    func dispose() {
        let first = disposeLock.withLock { () -> Bool in
            defer { disposed = true }
            return !disposed
        }
        guard first else { return }
        observer.unregister()
        AudioOutputUnitStop(unit)
        AudioUnitRemovePropertyListenerWithUserData(
            unit, kAudioOutputUnitProperty_IsRunning, halRunningListener,
            Unmanaged.passUnretained(context).toOpaque())
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        context.setRunning(false)
    }
}

/// The serial queue capture units are built, started and torn down on.
/// CoreAudio can keep a unit's device or format calls busy for seconds, or
/// forever, after a device change. Work that never returns has its queue
/// abandoned for a fresh one, so later captures are not queued behind it.
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
    /// Builds, starts and tears down capture units away from the main actor.
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
    private let renderFailureCount = CaptureSampleCountBox()
    private var spool: OrdinaryAudioSpool?
    private let conversionFailures = ConversionFailureBox()
    private var active: PreparedCapture?
    /// Dictation and the meeting microphone each own an instance, so the stall
    /// sampler's "audio is live" set needs a per-instance key.
    private let captureActivitySource = "microphone-\(UUID().uuidString)"
    private var ready: PreparedCapture?
    /// Bumped by every stop, so a start still waiting for its unit knows it
    /// was superseded.
    private var startGeneration = 0
    private var readyGeneration = 0
    private var readyAdoptedAt: TimeInterval = 0
    private var lastReadyRebuildAt: TimeInterval?
    /// A background build for the next capture, until it becomes `ready` or a
    /// press claims it.
    private var preparation: Preparation?

    private struct Preparation {
        let selection: AudioInputSelection
        let generation: Int
        let task: Task<PreparedCapture?, Never>
    }
    /// The capture whose device changes end the current capture.
    private var observedCapture: PreparedCapture?
    private var interruptionWatchdog: Task<Void, Never>?
    private var configurationObservationGate = AudioConfigurationObservationGate()

    /// Keep a prepared unit for the next capture. Dictation opts in; the
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
        renderFailureCount.reset()
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
            // A press soon after launch or a device change: use the unit
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
            // Stopped, or started again, while the unit was being built.
            Self.retire(capture)
            throw CancellationError()
        }

        // Observe before starting: a change while the unit starts must not
        // be missed.
        let observation = observeConfigurationChanges(for: capture)
        capture.sink.begin(CaptureSink.Session(
            spool: spool,
            store: samples,
            retainSamples: retainSamples,
            failures: conversionFailures,
            sampleCount: capturedSampleCount,
            deliveredBuffers: deliveredBufferCount,
            renderFailures: renderFailureCount,
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
        capture.beginDelivery()

        do {
            try await Self.startUnit(capture)
        } catch {
            capture.finishDelivery()
            capture.sink.end()
            if generation == startGeneration { stopObservingConfigurationChanges() }
            // A start that timed out is still inside CoreAudio on the abandoned
            // queue; its late completion retires the unit there.
            if case AudioCaptureServiceError.engineTimedOut = error {} else { Self.retire(capture) }
            throw error
        }
        guard generation == startGeneration else {
            // Stopped, or started again, while the unit was starting. Whoever
            // bumped the generation already stopped observing.
            capture.observer.setHandler(nil)
            capture.finishDelivery()
            capture.sink.end()
            Self.retire(capture)
            throw CancellationError()
        }
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
        startInterruptionWatchdog(for: capture, generation: observation)
        logger.info(
            "Capture started",
            metadata: [
                "audio.input.kind":
                    "\(selection.persistedValue == "system-default" ? "default" : "specific")"
            ]
        )
    }

    /// Every device and format call can wait on CoreAudio, which can stay busy
    /// for seconds after a device change, so none of it may block the main
    /// actor. The engine queue also serializes builds with any preparation in
    /// flight, and with the stop of the unit being reused.
    nonisolated private static func makeCapture(
        reusing prepared: PreparedCapture?,
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor
    ) async throws -> PreparedCapture {
        try await onEngineQueue(timeout: engineBuildTimeoutSeconds, discardLate: { retire($0) }) {
            if let prepared {
                // A unit whose device changed since it was built records the
                // wrong format, or nothing.
                let state = CoreAudioDeviceCatalog.captureState(of: prepared.deviceID)
                if prepared.expectation.change(in: state) == nil { return prepared }
                prepared.dispose()
            }
            return try buildCapture(selection: selection, descriptor: descriptor)
        }
    }

    /// `AudioOutputUnitStart` opens the device; on a Bluetooth headset that
    /// waits for the call profile, so it runs on the engine queue too.
    nonisolated private static func startUnit(_ capture: PreparedCapture) async throws {
        _ = try await onEngineQueue(timeout: engineBuildTimeoutSeconds, discardLate: { retire($0) }) {
            let status = AudioOutputUnitStart(capture.unit)
            guard status == noErr else { throw osStatusError(status) }
            capture.context.setRunning(true)
            return capture
        }
    }

    /// Prepares a unit for the next capture on `selection` in the background.
    func prepareCapture(for selection: AudioInputSelection) {
        guard keepsCaptureReady, active == nil else { return }
        if let ready, ready.selection == selection { return }
        if let preparation, preparation.selection == selection { return }
        discardReadyCapture()
        let generation = readyGeneration
        let task = Task.detached(priority: .userInitiated) { () -> PreparedCapture? in
            guard let descriptor = CoreAudioDeviceCatalog.resolve(selection),
                  CoreAudioDeviceCatalog.keepsEngineReady(for: descriptor.transientID, selection: selection)
            else { return nil }
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

    /// The device list changed: a prepared unit may point at stale hardware.
    func invalidatePreparedCapture() {
        discardReadyCapture()
    }

    private func adoptReadyCapture(_ capture: PreparedCapture) {
        ready = capture
        readyAdoptedAt = ProcessInfo.processInfo.systemUptime
        capture.observer.setHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.ready === capture else { return }
                // The device changed under the idle unit. Rebuild once the
                // change has settled, rather than querying it mid-change.
                let now = ProcessInfo.processInfo.systemUptime
                guard let delay = ReadyEngineRebuildPolicy.rebuildDelay(
                    changeAt: now, adoptedAt: self.readyAdoptedAt, lastRebuildAt: self.lastReadyRebuildAt
                ) else { return }
                let selection = capture.selection
                self.discardReadyCapture()
                let generation = self.readyGeneration
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.readyGeneration == generation else { return }
                self.lastReadyRebuildAt = ProcessInfo.processInfo.systemUptime
                self.prepareCapture(for: selection)
            }
        }
    }

    /// The prepared unit, if it still matches the device. The caller checks
    /// the device's format off the main actor.
    private func takeReadyCapture(selection: AudioInputSelection, deviceID: AudioDeviceID) -> PreparedCapture? {
        guard let ready else { return nil }
        guard ready.selection == selection, ready.deviceID == deviceID else {
            discardReadyCapture()
            return nil
        }
        ready.observer.setHandler(nil)
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
        ready?.observer.setHandler(nil)
        if let ready { Self.retire(ready) }
        ready = nil
    }

    /// An input-only AUHAL on `descriptor`'s device, initialized but not
    /// started. A system-default selection resolves the default input when the
    /// unit is built and is pinned to it; the device listeners catch the
    /// default moving later.
    nonisolated private static func buildCapture(
        selection: AudioInputSelection,
        descriptor: AudioInputDescriptor
    ) throws -> PreparedCapture {
        let deviceID = descriptor.transientID
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr,
              let unit = instance
        else { throw AudioCaptureServiceError.deviceUnavailable }
        var owned = false
        defer { if !owned { AudioComponentInstanceDispose(unit) } }

        // Input on and output off before the device is assigned. With no
        // output the unit never opens the default output device, and builds
        // none of the default-device aggregate AVAudioEngine did.
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, flagSize))
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize))

        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureServiceError.deviceAssignmentFailed(status)
        }
        let builtState = CoreAudioDeviceCatalog.captureState(of: deviceID)
        guard builtState.isAlive else { throw AudioCaptureServiceError.deviceUnavailable }

        // The device side of the input element: its rate, and its channels
        // across every input stream.
        var hardware = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize
        ) == noErr else { throw AudioCaptureServiceError.invalidInputFormat }
        var sliceFrames: UInt32 = 0
        var sliceSize = flagSize
        let sliceLimit = AudioUnitGetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &sliceFrames, &sliceSize
        ) == noErr ? Int(sliceFrames) : nil
        let plan: HALInputCapturePlan
        do {
            plan = try HALInputCapturePlan(
                sampleRate: hardware.mSampleRate,
                channelCount: Int(hardware.mChannelsPerFrame),
                maximumFramesPerSlice: sliceLimit,
                deviceBufferFrameSizeLimit: CoreAudioDeviceCatalog.bufferFrameSizeLimit(of: deviceID)
            )
        } catch {
            throw AudioCaptureServiceError.invalidInputFormat
        }

        // The client side: float, deinterleaved, at the device's own rate and
        // channel count, so the unit only changes sample format.
        var client = AudioStreamBasicDescription(
            mSampleRate: plan.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(plan.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, formatSize
        ) == noErr else { throw AudioCaptureServiceError.invalidInputFormat }
        var renderFrames = UInt32(plan.renderCapacityFrames)
        _ = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &renderFrames, flagSize)

        let context = HALInputContext(unit: unit, plan: plan)
        let processor = try CaptureChunkProcessor(plan: plan, ring: context.ring, targetSampleRate: targetSampleRate)
        let capture = PreparedCapture(
            selection: selection,
            deviceID: deviceID,
            expectation: CaptureDeviceExpectation(
                deviceID: deviceID, builtWith: builtState, followsSystemDefault: selection == .systemDefault),
            context: context,
            processor: processor
        )
        // From here the capture owns the unit, and disposes it on failure.
        owned = true
        do {
            let refCon = Unmanaged.passUnretained(context).toOpaque()
            var callback = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: refCon)
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            _ = AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_IsRunning, halRunningListener, refCon)
            try check(AudioUnitInitialize(unit))
        } catch {
            capture.dispose()
            throw error
        }
        capture.observer.register()
        return capture
    }

    nonisolated private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw osStatusError(status) }
    }

    nonisolated private static func osStatusError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    /// Without `downmix`, AVAudioConverter keeps only channel 0 of a
    /// multichannel input. `downmix` only helps layouts it understands, so
    /// the processor mixes float input itself and this covers other formats.
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

    /// One converted chunk into the running capture: the spool or the
    /// in-memory store, then the level meter and Meeting Mode's writer.
    nonisolated fileprivate static func deliver(_ result: Result<[Float], Error>, to session: CaptureSink.Session) {
        session.deliveredBuffers.add(1)
        do {
            let converted = try result.get()
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
                // Queued behind work that wedged: running now would touch
                // CoreAudio next to the replacement queue's.
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

    /// Stopping, uninitializing and disposing a unit can wait on CoreAudio;
    /// keep them off the caller.
    nonisolated private static func retire(_ capture: PreparedCapture) {
        engineQueue.async { capture.dispose() }
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
        // Render failures count only when nothing was captured at all: then,
        // like failed conversions, they explain an empty capture that is not
        // silence.
        let failureCount = conversionFailures.value
            + (capturedSampleCount.value == 0 ? renderFailureCount.value : 0)
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
                conversionFailureCount: max(1, failureCount),
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
            conversionFailureCount: failureCount,
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
        renderFailureCount.reset()
        onLevel?(0, 0)
    }

    /// `reusable`: the capture ended normally, so its unit can serve the next
    /// one and only a device change costs a build.
    private func stopEngine(reusable: Bool = false) {
        startGeneration &+= 1
        stopObservingConfigurationChanges()
        guard let active else { return }
        self.active = nil
        Observability.setAudioCaptureActive(false, source: captureActivitySource)
        // Every buffered frame is in the spool before the caller reads it;
        // only CoreAudio's stop is deferred.
        active.finishDelivery()
        active.sink.end()
        // A Bluetooth microphone is released at once, so the headset returns
        // to its high-quality playback profile as soon as dictation ends.
        if reusable, keepsCaptureReady, ready == nil,
           CoreAudioDeviceCatalog.keepsEngineReady(for: active.deviceID, selection: active.selection) {
            Self.engineQueue.async {
                AudioOutputUnitStop(active.unit)
                active.context.setRunning(false)
            }
            adoptReadyCapture(active)
        } else {
            Self.retire(active)
        }
    }

    /// Device listeners compare the device with how it was when the unit was
    /// built, so the changes CoreAudio posts while the unit starts are not
    /// mistaken for a lost microphone, and a real one ends the capture with
    /// the audio recorded so far.
    private func observeConfigurationChanges(for capture: PreparedCapture) -> UInt64 {
        stopObservingConfigurationChanges()
        let generation = configurationObservationGate.captureStarted()
        _ = configurationObservationGate.arm(generation)
        observedCapture = capture
        capture.observer.setHandler { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observedCapture === capture,
                      self.configurationObservationGate.shouldHandleChange(for: generation)
                else { return }
                self.reportInterruption(generation, cause: change.rawValue)
            }
        }
        return generation
    }

    /// Catches a unit that stops without a device change we saw, and buffers
    /// that stop arriving while the unit still claims to run.
    private func startInterruptionWatchdog(for capture: PreparedCapture, generation: UInt64) {
        interruptionWatchdog?.cancel()
        interruptionWatchdog = Task { @MainActor [weak self] in
            var detector = CaptureInterruptionDetector()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.active === capture,
                      self.configurationObservationGate.shouldHandleChange(for: generation)
                else { return }
                let running = capture.context.isRunning
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
        observedCapture?.observer.setHandler(nil)
        observedCapture = nil
    }

    nonisolated static func convert(
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
