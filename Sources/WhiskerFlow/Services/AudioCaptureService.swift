@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import WhiskerFlowAppSupport

enum Microphone {
    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    static func availableInputDevices() -> [AudioInputDescriptor] {
        CoreAudioDeviceCatalog.availableInputs()
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

@MainActor
private struct SystemAudioDeviceCatalog: AudioDeviceCataloging {
    func availableInputs() -> [AudioInputDescriptor] {
        CoreAudioDeviceCatalog.availableInputs()
    }

    func resolve(_ selection: AudioInputSelection) -> AudioInputDescriptor? {
        CoreAudioDeviceCatalog.resolve(selection)
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

@MainActor
final class AudioCaptureService: AudioCapturing {
    private static let targetSampleRate = 16_000.0
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.thatworks.WhiskerFlow",
        category: "AudioCapture"
    )
    private let catalog: any AudioDeviceCataloging
    private let samples = LockedAudioBuffer()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var configurationArmTask: Task<Void, Never>?
    private var configurationObservationGate = AudioConfigurationObservationGate()

    var onLevel: ((Float) -> Void)?
    var onConfigurationChange: (() -> Void)?

    init() {
        self.catalog = SystemAudioDeviceCatalog()
    }

    init(catalog: any AudioDeviceCataloging) {
        self.catalog = catalog
    }

    func start(selection: AudioInputSelection) throws {
        discardCapture()
        samples.reset()

        guard let descriptor = catalog.resolve(selection) else {
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
                logger.error("Device assignment failed status=\(status, privacy: .public)")
                throw AudioCaptureServiceError.deviceAssignmentFailed(status)
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
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

        inputNode.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self] buffer, _ in
            do {
                let converted = try Self.convert(
                    buffer,
                    converter: converterBox.converter,
                    targetFormat: targetFormat
                )
                store.append(converted)
                let level = Self.level(from: converted)
                Task { @MainActor [weak self] in self?.onLevel?(level) }
            } catch {
                Task { @MainActor [weak self] in
                    self?.logger.error("Audio conversion failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            armConfigurationObservation(for: engine)
            logger.info("Capture started selection=\(selection.persistedValue == "system-default" ? "default" : "specific", privacy: .public)")
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func snapshot() -> [Float] {
        samples.snapshot()
    }

    func stop(reason: CaptureStopReason) -> CapturedAudio {
        stopEngine()
        onLevel?(0)
        return CapturedAudio(samples: samples.drain(), stopReason: reason)
    }

    func cancel() {
        stopEngine()
        samples.reset()
        onLevel?(0)
    }

    private func discardCapture() {
        stopEngine()
        samples.reset()
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
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw CocoaError(.fileNoSuchFile) }
        let folder = root.appendingPathComponent("WhiskerFlow/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(UUID().uuidString).wav")
    }
}
