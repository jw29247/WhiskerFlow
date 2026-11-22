import ApplicationServices
import CoreGraphics
import Foundation
import os
import WhiskerFlowCore

/// A `CGEventTap` that swallows the shortcuts WhiskerFlow acts on, so they do
/// not also reach the front app. Which events those are is decided by
/// `ShortcutEventFilter`; this type only moves events in and decisions out.
///
/// Safety rules:
/// - The tap runs on its own thread with its own run loop, never the main
///   thread, so a busy main actor cannot delay anyone's typing or time the tap
///   out. The callback matches the event under a lock, posts any action to the
///   main queue and returns at once.
/// - It is installed only while the filter says a case can apply, and listens
///   for modifier changes only when a key-combination dictation shortcut needs
///   them. fn/Globe never passes through it.
/// - macOS disables a tap that is slow or interrupted by user input; the
///   callback re-enables it immediately.
/// - If the tap cannot be created (Accessibility not granted), `isActive`
///   stays false and the app keeps today's observing monitors. A slow retry
///   checks the cheap trust flag first and creates the tap once granted.
final class ShortcutEventTap: @unchecked Sendable {
    struct Event: Sendable {
        let kind: ShortcutEventFilter.EventKind
        let keyCode: UInt16
        let modifiers: KeyModifiers
        let isRepeat: Bool
        let timestamp: TimeInterval
    }

    private let filter: OSAllocatedUnfairLock<ShortcutEventFilter>
    /// Called on the main queue for every decision that needs the app.
    private let onDecision: @MainActor @Sendable (ShortcutEventFilter.Decision, Event) -> Void
    /// Called on the main queue when the tap starts or stops swallowing events.
    private let onActiveChange: @MainActor @Sendable (Bool) -> Void

    // Owned by the tap thread.
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var installedMask: CGEventMask = 0
    private var retryTimer: CFRunLoopTimer?
    private let ready = DispatchSemaphore(value: 0)

    private static let retryInterval: CFTimeInterval = 3

    init(filter: ShortcutEventFilter,
         onDecision: @escaping @MainActor @Sendable (ShortcutEventFilter.Decision, Event) -> Void,
         onActiveChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.filter = OSAllocatedUnfairLock(initialState: filter)
        self.onDecision = onDecision
        self.onActiveChange = onActiveChange
    }

    /// Starts the tap thread. Returns without waiting for the tap itself.
    func start() {
        guard runLoop == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            self.ready.signal()
            self.reconcile()
            // Keeps the run loop alive while no tap source is installed.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "WhiskerFlow shortcut tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func stop() {
        update { $0.isSuspended = true; $0.setDictationCombo(nil); $0.meetingCombo = nil; $0.isDictationRecording = false }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            self.removeTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
    }

    /// Changes what the filter matches. Cheap: a lock, and a hop to the tap
    /// thread only when whether the tap is needed or its mask changes.
    func update(_ change: (inout ShortcutEventFilter) -> Void) {
        let (before, after) = filter.withLock { state -> ((Bool, Bool), (Bool, Bool)) in
            let before = (state.needsTap, state.needsFlagsChanged)
            change(&state)
            return (before, (state.needsTap, state.needsFlagsChanged))
        }
        guard before != after, let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in self?.reconcile() }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Tap thread

    private func reconcile() {
        let (needed, flags) = filter.withLock { ($0.needsTap, $0.needsFlagsChanged) }
        guard needed else {
            removeTap()
            return
        }
        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        if flags { mask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue) }
        guard port == nil || mask != installedMask else { return }
        removeTap()
        installTap(mask: mask)
    }

    private func installTap(mask: CGEventMask) {
        guard AXIsProcessTrusted(), let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: shortcutTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            scheduleRetry()
            return
        }
        cancelRetry()
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        installedMask = mask
        reportActive(true)
    }

    private func removeTap() {
        cancelRetry()
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        installedMask = 0
        reportActive(false)
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + Self.retryInterval, Self.retryInterval, 0, 0
        ) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.cancelRetry()
            self.reconcile()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        retryTimer = timer
    }

    private func cancelRetry() {
        guard let retryTimer else { return }
        CFRunLoopTimerInvalidate(retryTimer)
        self.retryTimer = nil
    }

    private func reportActive(_ active: Bool) {
        let onActiveChange = onActiveChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onActiveChange(active) } }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        let kind: ShortcutEventFilter.EventKind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
        let shortcutEvent = Event(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: KeyModifiers(rawValue: UInt(event.flags.rawValue)),
            isRepeat: kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            // When the tap saw it, so the logged delay is the hop to the main queue.
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        let decision = filter.withLock {
            $0.decide(kind: kind, keyCode: shortcutEvent.keyCode,
                      modifiers: shortcutEvent.modifiers, isRepeat: shortcutEvent.isRepeat)
        }
        if decision.needsMainThread {
            let onDecision = onDecision
            DispatchQueue.main.async { MainActor.assumeIsolated { onDecision(decision, shortcutEvent) } }
        }
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }
}

private func shortcutTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ShortcutEventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
