import Foundation
import Logging
import OpenTelemetryApi

final class MainThreadHealthMonitor: @unchecked Sendable {
    static let shared = MainThreadHealthMonitor()
    private let queue = DispatchQueue(label: "WhiskerFlow.responsiveness", qos: .utility)
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    private var timer: DispatchSourceTimer?
    private var probe = ResponsivenessProbe()
    private var ticks = 0
    private let resources = ResourceDiagnosticSampler()
    private let stacks = StallStackCapture()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pressure = "unknown"
    private var audioCaptureSources: Set<String> = []
    private var interaction: [String: String] = [:]
    private var interactionUpdatedAt: TimeInterval?
    private var isSleeping = false
    private var stallID: String?
    /// Called by audio capture owners so stall diagnosis never pauses the process mid-capture.
    func setAudioCaptureActive(_ active: Bool, source: String) {
        queue.async { [self] in
            if active { audioCaptureSources.insert(source) } else { audioCaptureSources.remove(source) }
        }
    }

    func updateInteraction(_ context: InteractionDiagnosticContext) {
        queue.async { [self] in
            let fields = context.fields
            interactionUpdatedAt = ProcessInfo.processInfo.systemUptime
            if fields != interaction {
                interaction = fields
                var metadata = fields
                metadata["event"] = "interaction_state"
                logger.info("Keyboard and application diagnostic state changed", metadata: metadata.mapValues { .string($0) })
            }
        }
    }

    func setSleeping(_ sleeping: Bool) {
        queue.async { [self] in
            isSleeping = sleeping
            probe.reset()
            stallID = nil
            logger.info("System sleep state changed", metadata: ["event": sleeping ? "system_sleep" : "system_wake"])
        }
    }
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
            source.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }
    private func tick() {
        guard !isSleeping else { return }
        ticks += 1
        if ticks % 60 == 0 { logResources() }
        if ticks % 240 == 0 {
            var fields = contextFields()
            fields["event"] = "heartbeat"
            logger.info("Main thread health heartbeat", metadata: fields.mapValues { .string($0) })
        }
        handle(probe.tick(at: ProcessInfo.processInfo.systemUptime), captureStacks: true)
    }

    private func handle(_ events: [ResponsivenessProbe.Event], captureStacks: Bool) {
        for event in events {
            switch event {
            case let .enqueue(id):
                DispatchQueue.main.async { [self] in
                    let respondedAt = ProcessInfo.processInfo.systemUptime
                    queue.async { [self] in
                        handle(probe.acknowledge(id, at: respondedAt), captureStacks: false)
                    }
                }
            case let .stalled(elapsed):
                stallID = UUID().uuidString
                var fields = resources.snapshot().merging(contextFields()) { _, new in new }
                fields["event"] = "main_thread_stalled"
                fields["elapsed_ms"] = String(elapsed * 1000)
                fields["stall_id"] = stallID
                logger.warning("Main thread response delayed", metadata: fields.mapValues { .string($0) })
                Observability.mainThreadStalls.add(value: 1)
                if captureStacks {
                    stacks.captureIfNeeded(memoryPressure: pressure, audioCaptureActive: !audioCaptureSources.isEmpty)
                }
            case let .recovered(elapsed):
                var fields = contextFields()
                fields["event"] = "main_thread_recovered"
                fields["elapsed_ms"] = String(elapsed * 1000)
                fields["stall_id"] = stallID
                logger.notice("Main thread responding again", metadata: fields.mapValues { .string($0) })
                Observability.mainThreadStallDuration.record(value: elapsed)
                stallID = nil
            case let .monitoringGap(elapsed):
                stallID = nil
                logger.notice("Responsiveness monitoring resumed after scheduling gap", metadata: ["event": "monitoring_gap", "elapsed_ms": "\(elapsed * 1000)"])
            }
        }
    }

    private func contextFields() -> [String: String] {
        var fields = interaction
        fields["memory_pressure"] = pressure
        fields["audio_capture_active"] = String(!audioCaptureSources.isEmpty)
        if let interactionUpdatedAt {
            fields["context_age_ms"] = String(max(0, ProcessInfo.processInfo.systemUptime - interactionUpdatedAt) * 1000)
        }
        return fields
    }

    private func logResources() {
        var fields = resources.snapshot().merging(contextFields()) { _, new in new }
        fields["event"] = "resource_snapshot"
        logger.info("System resource snapshot", metadata: fields.mapValues { .string($0) })
    }
}
