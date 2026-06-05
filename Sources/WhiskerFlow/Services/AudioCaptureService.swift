import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Records microphone audio to a file and publishes a live input level.
///
/// All mutable state is confined to a private serial queue, and the recording
/// delegate (called on an arbitrary thread) hops onto that queue — so there is
/// no data race between `stop()` and the completion callback.
final class AudioCaptureService: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "agency.thatworks.whiskerflow.recorder")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var configuredDeviceID: String?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var meterTimer: DispatchSourceTimer?
    private var idleTeardown: DispatchWorkItem?

    /// Normalized 0...1 input level, delivered on the main queue while recording.
    var onLevel: ((Float) -> Void)?

    private static let idleKeepAlive: TimeInterval = 90

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Start the capture session ahead of time so recording begins instantly
    /// (avoids the start-up ramp that clips the first word).
    func prewarm(deviceID: String?) {
        queue.async { [weak self] in
            try? self?.ensureSession(deviceID: deviceID)
        }
    }

    func start(deviceID: String?) throws {
        try queue.sync {
            try ensureSession(deviceID: deviceID)
            cancelIdleTeardown()

            guard let output else { throw AudioCaptureError.cannotConfigureDevice }
            let url = try Self.makeRecordingURL()
            output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            recordingURL = url
            startMetering()
        }
    }

    func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioCaptureError.notRecording)
                    return
                }
                self.stopMetering()

                guard let output = self.output, let url = self.recordingURL else {
                    continuation.resume(throwing: AudioCaptureError.notRecording)
                    return
                }

                if output.isRecording {
                    self.stopContinuation = continuation
                    output.stopRecording()
                } else {
                    self.recordingURL = nil
                    continuation.resume(returning: url)
                }
                self.scheduleIdleTeardown()
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let continuation = self.stopContinuation
            self.stopContinuation = nil
            self.recordingURL = nil

            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: outputFileURL)
            }
        }
    }

    // MARK: - Session

    private func ensureSession(deviceID: String?) throws {
        let resolvedID = deviceID?.isEmpty == false ? deviceID : nil

        if session != nil, configuredDeviceID == resolvedID {
            if session?.isRunning == false { session?.startRunning() }
            return
        }

        teardownSession()

        let device = try selectedDevice(for: resolvedID)
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioFileOutput()

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AudioCaptureError.cannotConfigureDevice
        }

        session.addInput(input)
        session.addOutput(output)
        session.startRunning()

        self.session = session
        self.output = output
        self.configuredDeviceID = resolvedID
    }

    private func teardownSession() {
        session?.stopRunning()
        session = nil
        output = nil
        configuredDeviceID = nil
    }

    private func selectedDevice(for deviceID: String?) throws -> AVCaptureDevice {
        if let deviceID, !deviceID.isEmpty {
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
            if let device = devices.first(where: { $0.uniqueID == deviceID }) {
                return device
            }
        }

        if let device = AVCaptureDevice.default(for: .audio) {
            return device
        }

        throw AudioCaptureError.noInputDevice
    }

    private static func makeRecordingURL() throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhiskerFlow/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    // MARK: - Metering

    private func startMetering() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.output?.connection(with: .audio) else { return }
            let level = Self.normalizedLevel(from: connection)
            if let onLevel = self.onLevel {
                DispatchQueue.main.async { onLevel(level) }
            }
        }
        meterTimer?.cancel()
        meterTimer = timer
        timer.resume()
    }

    private func stopMetering() {
        meterTimer?.cancel()
        meterTimer = nil
        if let onLevel { DispatchQueue.main.async { onLevel(0) } }
    }

    private static func normalizedLevel(from connection: AVCaptureConnection) -> Float {
        let powers = connection.audioChannels.map(\.averagePowerLevel)
        guard let peak = powers.max() else { return 0 }
        // averagePowerLevel is dBFS (-160...0). Map roughly -50dB...0dB to 0...1.
        let floor: Float = -50
        let clamped = max(floor, min(0, peak))
        return (clamped - floor) / -floor
    }

    // MARK: - Idle teardown

    private func scheduleIdleTeardown() {
        cancelIdleTeardown()
        let work = DispatchWorkItem { [weak self] in
            self?.teardownSession()
        }
        idleTeardown = work
        queue.asyncAfter(deadline: .now() + Self.idleKeepAlive, execute: work)
    }

    private func cancelIdleTeardown() {
        idleTeardown?.cancel()
        idleTeardown = nil
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case cannotConfigureDevice
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input device is available."
        case .cannotConfigureDevice:
            return "The selected microphone could not be configured."
        case .notRecording:
            return "No active recording is available."
        }
    }
}
