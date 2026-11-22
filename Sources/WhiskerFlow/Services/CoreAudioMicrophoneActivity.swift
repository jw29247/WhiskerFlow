import CoreAudio
import Foundation

/// Reports the moment any process starts or stops using an input device, so
/// call detection can poll slowly while nothing uses the microphone. Nothing
/// is opened or read here: it only listens to the same CoreAudio properties a
/// call-detection poll reads (the process list and each process's "running
/// input" flag), plus each input device's "running somewhere" flag as a
/// second signal. A change only wakes the detector, which then polls.
@MainActor
final class CoreAudioMicrophoneActivity: MicrophoneActivitySource {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var onChange: (@MainActor () -> Void)?
    private var systemListeners: [Listener] = []
    private var processListeners: [AudioObjectID: Listener] = [:]
    private var deviceListeners: [AudioObjectID: Listener] = [:]

    func start(onChange: @escaping @MainActor () -> Void) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard self.onChange == nil else { return true }
        self.onChange = onChange
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Each listener is recorded as soon as it is registered, so `stop()`
        // removes the first even when the second cannot be registered.
        guard let processes = listen(system, kAudioHardwarePropertyProcessObjectList, onChange: { $0.processListChanged() }) else {
            stop()
            return false
        }
        systemListeners.append(processes)
        guard let devices = listen(system, kAudioHardwarePropertyDevices, onChange: { $0.deviceListChanged() }) else {
            stop()
            return false
        }
        systemListeners.append(devices)
        guard syncProcesses(), syncDevices() else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        for listener in systemListeners + Array(processListeners.values) + Array(deviceListeners.values) {
            remove(listener)
        }
        systemListeners = []
        processListeners = [:]
        deviceListeners = [:]
        onChange = nil
    }

    /// A change already queued for the main queue can arrive after `stop()`;
    /// it must not register listeners again.
    private func processListChanged() {
        guard onChange != nil else { return }
        _ = syncProcesses()
        onChange?()
    }

    private func deviceListChanged() {
        guard onChange != nil else { return }
        _ = syncDevices()
        onChange?()
    }

    /// Listens to every process object's input flag. False if one could not
    /// be watched: a change it missed would go unseen until the safety poll.
    @discardableResult
    private func syncProcesses() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        return sync(&processListeners, objects: CoreAudioProcesses.processObjectIDs(),
                    selector: kAudioProcessPropertyIsRunningInput)
    }

    /// Listens to every input device's "running somewhere" flag. Output-only
    /// devices are left out: playback must not wake the detector.
    @discardableResult
    private func syncDevices() -> Bool {
        sync(&deviceListeners, objects: Self.deviceIDs().filter(Self.hasInput),
             selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    private func sync(_ listeners: inout [AudioObjectID: Listener], objects: [AudioObjectID],
                      selector: AudioObjectPropertySelector) -> Bool {
        let current = Set(objects)
        for (object, listener) in listeners where !current.contains(object) {
            remove(listener)
            listeners[object] = nil
        }
        var complete = true
        for object in current where listeners[object] == nil {
            if let listener = listen(object, selector, onChange: { $0.onChange?() }) {
                listeners[object] = listener
            } else {
                complete = false
            }
        }
        return complete
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        onChange: @escaping @MainActor (CoreAudioMicrophoneActivity) -> Void) -> Listener? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                onChange(self)
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
