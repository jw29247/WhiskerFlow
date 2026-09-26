import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import Logging
import Observation
import WhiskerFlowAppSupport

/// What the detector reads each poll. Titles stay in memory only.
struct CallDetectionSignals: Sendable {
    var inputs: [AudioInputProcess]
    var windows: [AppWindowTitles]
}

/// Watches for calls natively: which processes use the microphone (CoreAudio
/// process objects) and, only for a browser that is using it, the titles of
/// its windows and tabs (Accessibility). Nothing is installed in any app,
/// nothing is recorded, and nothing leaves the Mac.
@MainActor
@Observable
final class CallDetectionService {
    static let pollSeconds: UInt64 = 3

    private(set) var activeCalls: [DetectedCall] = []
    @ObservationIgnored var onEvent: ((CallSessionTracker.Event) -> Void)?
    @ObservationIgnored private var tracker = CallSessionTracker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let readSignals: @Sendable () -> CallDetectionSignals
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private var lastUnrecognisedReport: TimeInterval?
    @ObservationIgnored private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

    init(
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        readSignals: @escaping @Sendable () -> CallDetectionSignals = { NativeCallSignalReader.read() }
    ) {
        self.ownBundleID = ownBundleID
        self.readSignals = readSignals
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        logger.info("Call detection started", metadata: [
            "event": "call_detection_started", "accessibility": "\(AXIsProcessTrusted())",
        ])
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tracker = CallSessionTracker()
        activeCalls = []
    }

    func poll(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        let read = readSignals
        let signals = await Task.detached(priority: .utility) { read() }.value
        let calls = CallDetectionRules.detect(inputs: signals.inputs, windows: signals.windows, ownBundleID: ownBundleID)
        let owners = Set(signals.inputs.compactMap { CallDetectionRules.owningApp(ofProcessBundleID: $0.bundleID) })
        reportUnrecognisedBrowserCapture(signals: signals, owners: owners, calls: calls, now: now)
        let events = tracker.observe(calls, appsUsingMicrophone: owners, at: now)
        let active = tracker.activeCalls
        if active != activeCalls { activeCalls = active }
        for event in events { onEvent?(event) }
    }
}

extension CallDetectionService {
    /// A browser is using the microphone but no call was recognised: log what
    /// the reader could see, as counts and shapes only (never a title), at
    /// most once a minute, so a missed call can be diagnosed.
    fileprivate func reportUnrecognisedBrowserCapture(
        signals: CallDetectionSignals, owners: Set<String>, calls: [DetectedCall], now: TimeInterval
    ) {
        let browsers = owners.filter { CallDetectionRules.browsers.contains($0) || $0 == "com.apple.WebKit" }
        guard !browsers.isEmpty, calls.isEmpty else { return }
        if let last = lastUnrecognisedReport, now - last < 60 { return }
        lastUnrecognisedReport = now
        let titles = signals.windows.flatMap(\.titles)
        logger.info("Browser microphone use without a recognised call", metadata: [
            "event": "call_unrecognised",
            "owners": "\(browsers.sorted().joined(separator: ","))",
            "accessibility": "\(AXIsProcessTrusted())",
            "window_sources": "\(signals.windows.count)",
            "titles": "\(titles.count)",
            "titles_with_meet": "\(titles.filter { $0.lowercased().contains("meet") }.count)",
            "titles_with_code": "\(titles.filter { CallDetectionRules.meetCode(in: $0) != nil }.count)",
        ])
    }
}

/// Reads the two native signals. Runs off the main actor.
enum NativeCallSignalReader {
    /// Per-element Accessibility timeout, and a bound on the tree walk.
    private static let axTimeout: Float = 0.25
    private static let maximumNodes = 400
    private static let maximumDepth = 12

    static func read() -> CallDetectionSignals {
        let inputs = processesUsingMicrophone()
        let owners = Set(inputs.compactMap { CallDetectionRules.owningApp(ofProcessBundleID: $0.bundleID) })
        // Titles are read only for browsers that are using the microphone.
        var browserIDs = owners.intersection(CallDetectionRules.browsers)
        if owners.contains("com.apple.WebKit") { browserIDs.formUnion(CallDetectionRules.webKitBrowsers) }
        // A browser's installed web apps (the Google Meet app, for example)
        // show the call in their own windows, so they count as the browser.
        guard !browserIDs.isEmpty else { return CallDetectionSignals(inputs: inputs, windows: []) }
        // Window names come from the window server, which covers every Space
        // and full-screen windows (a call is often full screen) and needs the
        // Screen Recording access Meeting Mode already has. Accessibility adds
        // background tab titles in the current Space.
        let windowNames = windowServerNames()
        let axTrusted = AXIsProcessTrusted()
        let windows: [AppWindowTitles] = NSWorkspace.shared.runningApplications.compactMap { app -> AppWindowTitles? in
            guard let owner = CallDetectionRules.titleSourceOwner(forAppBundleID: app.bundleIdentifier),
                  browserIDs.contains(owner) else { return nil }
            let pid = app.processIdentifier
            let names = windowNames[pid] ?? []
            return AppWindowTitles(bundleID: owner, titles: names + (axTrusted ? titles(pid: pid) : []))
        }
        return CallDetectionSignals(inputs: inputs, windows: windows)
    }

    /// Non-empty window names by owning process, from the window server.
    static func windowServerNames() -> [pid_t: [String]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var names: [pid_t: [String]] = [:]
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let name = window[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            names[pid, default: []].append(name)
        }
        return names
    }

    /// CoreAudio's per-process input state (macOS 14.2 and later).
    static func processesUsingMicrophone() -> [AudioInputProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid)
            return AudioInputProcess(pid: pid, bundleID: bundleID(object))
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    /// Window titles plus tab titles (tab strips expose tabs as radio buttons
    /// or tabs), from a bounded walk that skips web content.
    static func titles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var result: [String] = []
        var visited = 0
        for window in elements(app, kAXWindowsAttribute) {
            if let title = string(window, kAXTitleAttribute), !title.isEmpty { result.append(title) }
            var stack: [(AXUIElement, Int)] = [(window, 0)]
            while let (element, depth) = stack.popLast(), visited < maximumNodes {
                visited += 1
                let role = string(element, kAXRoleAttribute) ?? ""
                if role == "AXWebArea" { continue }
                if role == "AXRadioButton" || role == "AXTab",
                   let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute), !title.isEmpty {
                    result.append(title)
                    continue
                }
                guard depth < maximumDepth else { continue }
                stack.append(contentsOf: elements(element, kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
