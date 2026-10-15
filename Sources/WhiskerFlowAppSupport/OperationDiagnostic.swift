import Foundation
import Logging
import OpenTelemetryApi
import OpenTelemetrySdk

struct OperationDiagnostic {
    let operation: String
    let seconds: Double
    let isSlow: Bool

    init?(event: String, fields: [String: String]) {
        let threshold: Double
        let durationKey: String
        switch event {
        case "finish_returned":
            operation = "dictation.finish"
            threshold = 2
            durationKey = "elapsed_ms"
        case "paste_returned":
            operation = "dictation.paste"
            threshold = 2
            durationKey = "elapsed_ms"
        case "hotkey_transition":
            operation = "hotkey.dispatch"
            threshold = 0.25
            durationKey = "elapsed_ms"
        case "capture_start_timing":
            operation = "capture.start"
            threshold = 1
            durationKey = "engine_start_ms"
        case "stage_finished":
            guard let stage = fields["stage"],
                  ["recognition", "translation", "text_processing", "history_save", "ui_update", "completion_sound"].contains(stage) else { return nil }
            operation = stage
            threshold = stage == "recognition" ? 5 : 1
            durationKey = "elapsed_ms"
        default:
            return nil
        }
        guard let raw = fields[durationKey], let milliseconds = Double(raw), milliseconds.isFinite, milliseconds >= 0 else { return nil }
        seconds = milliseconds / 1000
        isSlow = seconds >= threshold
    }
}

struct PerformanceLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?
    var logLevel: Logging.Logger.Level = .info
    let duration: DoubleHistogramMeterSdk
    let slowOperations: LongCounterSdk

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var values = metadata
        if let provided = metadataProvider?.get() { values.merge(provided) { _, new in new } }
        if let explicit = event.metadata { values.merge(explicit) { _, new in new } }
        let fields = values.mapValues(\.description)
        guard let name = fields["event"], let observation = OperationDiagnostic(event: name, fields: fields) else { return }
        let attributes: [String: AttributeValue] = ["operation": .string(observation.operation)]
        duration.record(value: observation.seconds, attributes: attributes)
        if observation.isSlow { slowOperations.add(value: 1, attributes: attributes) }
    }
}
