import Foundation

public enum AudioInputSelection: Codable, Equatable, Hashable, Sendable {
    case systemDefault
    case device(uid: String)

    public var persistedValue: String {
        switch self {
        case .systemDefault: return "system-default"
        case .device(let uid): return uid
        }
    }

    public init(persistedValue: String?) {
        guard let persistedValue, !persistedValue.isEmpty, persistedValue != "system-default" else {
            self = .systemDefault
            return
        }
        self = .device(uid: persistedValue)
    }
}

public struct AudioInputDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let transientID: UInt32

    public init(uid: String, name: String, transientID: UInt32) {
        self.uid = uid
        self.name = name
        self.transientID = transientID
    }
}

public enum MicrophoneSelection {
    public static func migrate(
        legacyDeviceID: String?,
        devices: [AudioInputDescriptor]
    ) -> AudioInputSelection {
        guard let legacyDeviceID, let id = UInt32(legacyDeviceID),
              let device = devices.first(where: { $0.transientID == id }) else {
            return .systemDefault
        }
        return .device(uid: device.uid)
    }

    /// Keeps the user's preferred device even while it is disconnected. Capture
    /// can temporarily use the current system default and return to this UID when
    /// the device reappears.
    public static func reconcile(
        _ selection: AudioInputSelection,
        devices _: [AudioInputDescriptor]
    ) -> AudioInputSelection {
        selection
    }

    public static func captureCandidates(
        for preferred: AudioInputSelection,
        devices: [AudioInputDescriptor]
    ) -> [AudioInputSelection] {
        switch preferred {
        case .systemDefault:
            return [.systemDefault]
        case .device(let uid):
            return devices.contains(where: { $0.uid == uid })
                ? [preferred, .systemDefault]
                : [.systemDefault]
        }
    }
}

@MainActor
public protocol AudioDeviceCataloging {
    func availableInputs() -> [AudioInputDescriptor]
    func resolve(_ selection: AudioInputSelection) -> AudioInputDescriptor?
}
