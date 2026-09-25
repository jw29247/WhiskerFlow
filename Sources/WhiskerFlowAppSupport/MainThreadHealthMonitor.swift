import Foundation
import Logging

/// One outstanding main-queue probe; emits only stalls, recoveries and minute heartbeats.
final class MainThreadHealthMonitor: @unchecked Sendable {
    static let shared = MainThreadHealthMonitor()
    private let queue = DispatchQueue(label: "WhiskerFlow.responsiveness", qos: .utility)
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    private var timer: DispatchSourceTimer?
    private var pendingSince: TimeInterval?
    private var reported = false
    private var ticks = 0
    private let resources = ResourceDiagnosticSampler()
    private let stacks = StallStackCapture()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pressure = "unknown"
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
            memory.setEventHandler { [weak self, weak memory] in
                guard let self, let memory else { return }
                self.pressure = memory.data.contains(.critical) ? "critical" : (memory.data.contains(.warning) ? "warning" : "normal")
                self.logResources()
            }
            pressureSource = memory
            memory.resume()
            logResources()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        ticks += 1
        if ticks % 15 == 0 { logResources() }
        if ticks % 60 == 0 { logger.info("Main thread health heartbeat", metadata: ["event": "heartbeat"]) }
        if let since = pendingSince {
            if now - since >= 3, !reported {
                reported = true
                stacks.captureIfNeeded()
                logResources()
                logger.warning("Main thread response delayed", metadata: ["event": "main_thread_stalled", "elapsed_ms": "\((now - since) * 1000)"])
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [self] in
            queue.async { [self] in
                if reported, let since = pendingSince {
                    logResources()
                    logger.notice("Main thread responding again", metadata: ["event": "main_thread_recovered", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - since) * 1000)"])
                }
                reported = false
                pendingSince = nil
            }
        }
    }
    private func logResources() {
        var fields = resources.snapshot()
        fields["memory_pressure"] = pressure
        logger.info("System resource snapshot", metadata: fields.mapValues { .string($0) })
    }

}
