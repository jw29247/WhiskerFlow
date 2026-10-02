import Foundation

/// Accessibility is synchronous IPC. Neither a slow destination nor its IPC
/// timeout is allowed to hold the main actor or the caller's completion open.
public enum PasteVerification {
    public static func verify(timeout: TimeInterval = 0.9, minimumWait: TimeInterval = 0.45,
                              probe: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = VerificationResult(continuation)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let earliest = ProcessInfo.processInfo.systemUptime + minimumWait
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { result.complete(false) }
            DispatchQueue.global(qos: .utility).async {
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if probe() {
                        let remaining = earliest - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                        result.complete(ProcessInfo.processInfo.systemUptime < deadline)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.075)
                }
                result.complete(false)
            }
        }
    }
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
