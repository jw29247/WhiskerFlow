@preconcurrency import AVFoundation
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

@MainActor
final class AudioCaptureService {
    private static let targetSampleRate = 16_000.0
    private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.AudioCapture"
    )
    private let samples = LockedAudioBuffer()
    private let conversionFailures = ConversionFailureBox()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var configurationArmTask: Task<Void, Never>?
    private var configurationObservationGate = AudioConfigurationObservationGate()

    /// Normalized 0...1 RMS level plus the buffer's absolute peak.
    var onLevel: ((Float, Float) -> Void)?
    /// Normalized 16 kHz mono samples for Meeting Mode's durable writer.
    var onSamples: (([Float]) -> Void)?
    var onConfigurationChange: (() -> Void)?

    func start(selection: AudioInputSelection) throws {
        stopEngine()
        samples.reset()
        conversionFailures.reset()

        guard let descriptor = CoreAudioDeviceCatalog.resolve(selection) else {
            throw AudioCaptureServiceError.deviceUnavailable
        }

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
                logger.error(
                    "Device assignment failed",
                    metadata: ["core_audio.status": "\(status)"]
                )
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

        let converter: AVAudioConverter?
        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == targetFormat.channelCount,
           inputFormat.commonFormat == targetFormat.commonFormat {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            guard converter != nil else { throw AudioCaptureServiceError.converterUnavailable }
        }
        let converterBox = AudioConverterBox(converter: converter)
        let store = samples
        let failures = conversionFailures

        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self] buffer, _ in
            do {
                let converted = try Self.convert(
                    buffer,
                    converter: converterBox.converter,
                    targetFormat: targetFormat
                )
                store.append(converted)
                Task { @MainActor [weak self] in self?.onSamples?(converted) }
                let level = Self.level(from: converted)
                let peak = Self.peak(from: converted)
                Task { @MainActor [weak self] in self?.onLevel?(level, peak) }
            } catch {
                let isFirstFailure = failures.increment()
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
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            armConfigurationObservation(for: engine)
            logger.info(
                "Capture started",
                metadata: [
                    "audio.input.kind":
                        "\(selection.persistedValue == "system-default" ? "default" : "specific")"
                ]
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func sampleCount() -> Int {
        samples.count
    }

    func snapshotTail(from index: Int) -> [Float] {
        samples.suffix(from: index)
    }

    func stop(reason: CaptureStopReason) -> CapturedAudio {
        stopEngine()
        onLevel?(0, 0)
        return CapturedAudio(
            samples: samples.drain(),
            stopReason: reason,
            conversionFailureCount: conversionFailures.value
        )
    }

    func cancel() {
        stopEngine()
        samples.reset()
        conversionFailures.reset()
        onLevel?(0, 0)
    }

    private func stopEngine() {
        configurationArmTask?.cancel()
        configurationArmTask = nil
        configurationObservationGate.captureStopped()
        removeConfigurationObserver()
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
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
                  self.engine === engine,
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
        let sum = buffer.reduce(Float.zero) { $0 + ($1 * $1) }
        let rms = (sum / Float(buffer.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return (max(-50, min(0, db)) + 50) / 50
    }

    nonisolated private static func peak(from buffer: [Float]) -> Float {
        buffer.reduce(Float.zero) { max($0, abs($1)) }
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
