import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

final class AudioCaptureService: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?

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

        return discovery.devices.map { device in
            AudioInputDevice(id: device.uniqueID, name: device.localizedName)
        }
    }

    func start(deviceID: String?) throws {
        let device = try selectedDevice(for: deviceID)
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioFileOutput()

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AudioCaptureError.cannotConfigureDevice
        }

        session.addInput(input)
        session.addOutput(output)
        session.startRunning()

        let url = try Self.makeRecordingURL()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)

        self.session = session
        self.output = output
        self.recordingURL = url
    }

    func stop() async throws -> URL {
        guard let output, let recordingURL else {
            throw AudioCaptureError.notRecording
        }

        if !output.isRecording {
            cleanup()
            return recordingURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            output.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        session?.stopRunning()
        cleanup(keepingContinuation: true)

        if let error {
            stopContinuation?.resume(throwing: error)
        } else {
            stopContinuation?.resume(returning: outputFileURL)
        }

        stopContinuation = nil
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

    private func cleanup(keepingContinuation: Bool = false) {
        session = nil
        output = nil
        recordingURL = nil
        if !keepingContinuation {
            stopContinuation = nil
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case cannotConfigureDevice
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone input device is available."
        case .cannotConfigureDevice:
            "The selected microphone could not be configured."
        case .notRecording:
            "No active recording is available."
        }
    }
}
