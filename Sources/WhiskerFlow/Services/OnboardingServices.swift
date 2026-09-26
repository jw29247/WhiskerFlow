import AppKit
import CoreAudio
import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// First-run model download state for the setup screen.
struct ModelDownloadStatus: Equatable {
    /// Nil until a Parakeet preparation starts in this process.
    var tracker: StagedDownloadProgress?
    var needsDownload = false
    var isCompiling = false

    var fraction: Double { tracker?.overall ?? 0 }
}

/// `PasteService` never pastes into WhiskerFlow itself. During setup's practice
/// screen the user dictates into WhiskerFlow's own text field, so while a
/// practice field is registered, a dictation whose destination is this app is
/// handed to that field instead. Every other delivery passes straight through.
@MainActor
final class InAppPracticeDelivery: TextDeliveryService {
    private var base: any TextDeliveryService
    /// Set by the practice screen while it is visible.
    var practiceField: ((String) -> Void)?
    /// This app's process; injectable because a test host is not an app.
    var ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    init(base: any TextDeliveryService) {
        self.base = base
    }

    var hasAccessibilityPermission: Bool { base.hasAccessibilityPermission }
    func requestAccessibilityPermission() { base.requestAccessibilityPermission() }
    func copy(_ text: String) { base.copy(text) }

    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        await paste(text, into: application, replacing: selection, onPosted: {})
    }

    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?,
               onPosted: @escaping @MainActor () -> Void) async -> PasteDeliveryReceipt {
        if selection == nil, let practiceField,
           application?.processIdentifier == ownProcessIdentifier {
            let normalized = text.normalizedForDelivery
            practiceField(normalized)
            onPosted()
            return PasteDeliveryReceipt(state: .verified, text: normalized, message: "Pasted", retrySelection: nil)
        }
        return await base.paste(text, into: application, replacing: selection, onPosted: onPosted)
    }
}

/// Live input levels for setup's microphone check. Uses its own capture
/// instance, never the dictation one, and keeps no audio.
@MainActor
final class OnboardingMicrophoneProbe {
    private let capture = AudioCaptureService()
    private(set) var isRunning = false
    var onLevel: ((Float, Float) -> Void)? {
        didSet { capture.onLevel = onLevel }
    }

    func start(selection: AudioInputSelection, voiceProcessing: Bool) async throws {
        stop()
        capture.voiceProcessing = voiceProcessing
        capture.onLevel = onLevel
        // Running from the start, so a `stop()` while the engine builds cancels it.
        isRunning = true
        do {
            try await capture.start(selection: selection, retainSamples: false)
        } catch {
            // A cancelled start was stopped by whoever cancelled it.
            if !(error is CancellationError) { isRunning = false }
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.cancel()
        isRunning = false
    }
}

extension CoreAudioDeviceCatalog {
    /// The device a selection would record from right now, with how it connects.
    static func inputDetails(for selection: AudioInputSelection) -> (name: String, transport: AudioInputTransport)? {
        guard let descriptor = resolve(selection) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(descriptor.transientID, &address, 0, nil, &size, &transport) == noErr else {
            return (descriptor.name, .other)
        }
        let kind: AudioInputTransport
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: kind = .builtIn
        case kAudioDeviceTransportTypeUSB: kind = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = .bluetooth
        case kAudioDeviceTransportTypeVirtual: kind = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: kind = .aggregate
        default: kind = .other
        }
        return (descriptor.name, kind)
    }
}

@MainActor
enum AppRelauncher {
    /// Quits and reopens this copy of the app, for permissions macOS only
    /// applies at launch. Setup progress is already saved, so it resumes.
    static func relaunch() {
        guard !UIPreview.isEnabled else { return }
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit so `open` launches a fresh instance
        // instead of activating the one that is quitting.
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}

@MainActor
enum SystemSettingsLink {
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    static let sound = "x-apple.systempreferences:com.apple.Sound-Settings.extension"

    static func open(_ link: String) {
        guard !UIPreview.isEnabled, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}
