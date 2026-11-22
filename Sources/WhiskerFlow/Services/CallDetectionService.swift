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

/// Says when any process starts or stops using an input device, so call
/// detection can poll slowly while nothing uses the microphone.
@MainActor
protocol MicrophoneActivitySource: AnyObject {
    /// Starts observing. False when changes cannot be observed; the detector
    /// then keeps polling at its active cadence.
    func start(onChange: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

/// How long call detection waits between polls.
enum CallDetectionCadence {
    /// While another process uses the microphone or a call is being tracked:
    /// a call is confirmed by two polls, and its end after 15 s without one.
    static let activeSeconds: TimeInterval = 3
    /// While nothing else uses the microphone and a listener reports when
    /// that changes. A safety net only: a call starts with the microphone,
    /// and that wakes the detector at once.
    static let idleSeconds: TimeInterval = 30
    /// A burst of microphone changes (device, process list, process input)
    /// is read in one poll this long after the first.
    static let wakeSettleSeconds: TimeInterval = 1

    static func interval(otherAppsUseMicrophone: Bool, tracksCalls: Bool, observesMicrophone: Bool) -> TimeInterval {
        observesMicrophone && !otherAppsUseMicrophone && !tracksCalls ? idleSeconds : activeSeconds
    }
}

/// Watches for calls natively: which processes use the microphone (CoreAudio
/// process objects) and, only for a browser that is using it, the titles of
/// its windows and tabs (Accessibility). Nothing is installed in any app,
/// nothing is recorded, and nothing leaves the Mac.
@MainActor
@Observable
final class CallDetectionService {
    private(set) var activeCalls: [DetectedCall] = []
    @ObservationIgnored var onEvent: ((CallSessionTracker.Event) -> Void)?
    @ObservationIgnored private var tracker = CallSessionTracker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let readSignals: @Sendable () -> CallDetectionSignals
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private var lastUnrecognisedReport: TimeInterval?
    @ObservationIgnored private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    @ObservationIgnored private let microphoneActivity: MicrophoneActivitySource?
    @ObservationIgnored private let pause: CallDetectionPause
    @ObservationIgnored private let now: () -> TimeInterval
    /// Whether the last poll saw another process using the microphone.
    @ObservationIgnored private(set) var otherAppsUseMicrophone = false
    /// Whether microphone changes wake the detector, allowing the idle cadence.
    @ObservationIgnored private(set) var observesMicrophone = false

    /// - Parameters:
    ///   - microphoneActivity: wakes the detector when microphone use changes.
    ///     Without one it polls every `CallDetectionCadence.activeSeconds`.
    ///   - sleep, now: the clock between polls; tests inject a virtual one.
    init(
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        readSignals: @escaping @Sendable () -> CallDetectionSignals = { NativeCallSignalReader.read() },
        microphoneActivity: MicrophoneActivitySource? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0), tolerance: .milliseconds(500))
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.ownBundleID = ownBundleID
        self.readSignals = readSignals
        self.microphoneActivity = microphoneActivity
        self.now = now
        pause = CallDetectionPause(settleSeconds: CallDetectionCadence.wakeSettleSeconds, sleep: sleep)
    }

    var isRunning: Bool { task != nil }

    /// The wait after the last poll.
    var nextPollInterval: TimeInterval {
        CallDetectionCadence.interval(otherAppsUseMicrophone: otherAppsUseMicrophone,
                                      tracksCalls: tracker.isTracking, observesMicrophone: observesMicrophone)
    }

    func start() {
        guard task == nil else { return }
        observesMicrophone = microphoneActivity?.start { [weak self] in self?.microphoneActivityChanged() } ?? false
        logger.info("Call detection started", metadata: [
            "event": "call_detection_started", "accessibility": "\(AXIsProcessTrusted())",
            "observes_microphone": "\(observesMicrophone)",
        ])
        task = Task { @MainActor [weak self, pause] in
            var woken = true
            while !Task.isCancelled {
                guard let interval = await self?.pollAndPlan(woken: woken) else { return }
                woken = await pause.wait(seconds: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pause.cancel()
        microphoneActivity?.stop()
        observesMicrophone = false
        otherAppsUseMicrophone = false
        tracker = CallSessionTracker()
        activeCalls = []
    }

    /// A microphone change: poll shortly, whatever the cadence.
    func microphoneActivityChanged() {
        guard task != nil else { return }
        pause.wake()
    }

    func poll(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        let read = readSignals
        let signals = await Task.detached(priority: .utility) { read() }.value
        otherAppsUseMicrophone = signals.inputs.contains { $0.bundleID == nil || $0.bundleID != ownBundleID }
        let calls = CallDetectionRules.detect(inputs: signals.inputs, windows: signals.windows, ownBundleID: ownBundleID)
        let owners = Set(signals.inputs.compactMap { CallDetectionRules.owningApp(ofProcessBundleID: $0.bundleID) })
        reportUnrecognisedBrowserCapture(signals: signals, owners: owners, calls: calls, now: now)
        let events = tracker.observe(calls, appsUsingMicrophone: owners, at: now)
        let active = tracker.activeCalls
        if active != activeCalls { activeCalls = active }
        for event in events { onEvent?(event) }
    }

    /// Polls and returns how long to wait before the next poll. `woken` says
    /// whether a microphone change, rather than the timer, ended the wait.
    private func pollAndPlan(woken: Bool) async -> TimeInterval {
        let idleBefore = nextPollInterval == CallDetectionCadence.idleSeconds
        await poll(now: now())
        // A poll still in flight when detection was stopped (and perhaps
        // started again) must not switch the new run's listener off.
        guard !Task.isCancelled else { return nextPollInterval }
        if observesMicrophone, idleBefore, !woken, otherAppsUseMicrophone {
            // The safety-net poll found microphone use that no change
            // reported. Stop trusting the listener until detection restarts,
            // and poll at the active cadence as before.
            observesMicrophone = false
            microphoneActivity?.stop()
            logger.notice("Microphone change was not reported; polling at the active cadence", metadata: [
                "event": "call_detection_listener_missed",
            ])
        }
        return nextPollInterval
    }
}

/// The wait between polls, which a microphone change cuts short.
@MainActor
final class CallDetectionPause {
    private let settleSeconds: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    private var settling = false
    private var pendingWake = false

    init(settleSeconds: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.settleSeconds = settleSeconds
        self.sleep = sleep
    }

    /// Waits `seconds`, or only `settleSeconds` once woken (also by a wake
    /// that came during the previous poll). Returns whether a wake ended it.
    func wait(seconds: TimeInterval) async -> Bool {
        guard !Task.isCancelled else { return false }
        let woken = pendingWake
        pendingWake = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            settling = woken
            startTimer(seconds: woken ? settleSeconds : seconds, woken: woken)
        }
    }

    func wake() {
        guard continuation != nil else {
            pendingWake = true
            return
        }
        guard !settling else { return }
        settling = true
        timer?.cancel()
        startTimer(seconds: settleSeconds, woken: true)
    }

    /// Ends any wait and forgets a pending wake.
    func cancel() {
        pendingWake = false
        finish(woken: false)
    }

    private func startTimer(seconds: TimeInterval, woken: Bool) {
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            await sleep(seconds)
            guard !Task.isCancelled else { return }
            self?.finish(woken: woken)
        }
    }

    private func finish(woken: Bool) {
        timer?.cancel()
        timer = nil
        settling = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: woken)
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
        CoreAudioProcesses.current().filter(\.isRunningInput).map { AudioInputProcess(pid: $0.pid, bundleID: $0.bundleID) }
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
