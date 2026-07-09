import CoreAudio
import Foundation

@MainActor
final class AudioDeviceChangeMonitor {
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let onChange: () -> Void
    private var registrations: [Registration] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard registrations.isEmpty else { return }
        register(selector: kAudioHardwarePropertyDevices)
        register(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func stop() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &registration.address,
                .main,
                registration.block
            )
        }
        registrations.removeAll()
    }

    private func register(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            block
        ) == noErr else { return }
        registrations.append(Registration(address: address, block: block))
    }
}
