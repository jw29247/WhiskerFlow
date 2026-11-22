import Foundation

/// Accessibility is synchronous IPC. Neither a slow destination nor its IPC
/// timeout is allowed to hold the main actor or the caller's completion open.
public enum PasteVerification {
    public static func verify(timeout: TimeInterval = 0.9, minimumWait: TimeInterval = 0.45,
                              probe: @escaping @Sendable () -> Bool) async -> Bool {
        await verify(timeout: timeout, minimumWait: minimumWait, clock: .system, probe: probe)
    }

    /// Tests drive `clock` so the outcome never depends on machine speed.
    static func verify(timeout: TimeInterval, minimumWait: TimeInterval, clock: PasteVerificationClock,
                       probe: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = VerificationResult(continuation)
            let deadline = clock.now() + timeout
            let earliest = clock.now() + minimumWait
            clock.schedule(timeout) { result.complete(false) }
            DispatchQueue.global(qos: .utility).async {
                while clock.now() < deadline {
                    if probe() {
                        let remaining = earliest - clock.now()
                        if remaining > 0 { clock.sleep(remaining) }
                        result.complete(clock.now() < deadline)
                        return
                    }
                    clock.sleep(0.075)
                }
                result.complete(false)
            }
        }
    }
}

/// The time source, blocking sleep and deadline timer verification uses.
/// `system` is the real one; it follows the `now` closure convention of
/// `AudioSignalAssessment`.
struct PasteVerificationClock: Sendable {
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) -> Void
    /// Runs `work` once `delay` seconds have passed.
    var schedule: @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    static let system = PasteVerificationClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        schedule: { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { work() }
        }
    )
}

private final class VerificationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func complete(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
