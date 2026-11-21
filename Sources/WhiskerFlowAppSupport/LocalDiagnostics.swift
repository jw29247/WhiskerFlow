import Foundation
import Logging
import OSLog

/// On-device diagnostics: the unified system log, the allow-listed local
/// diagnostic log and main-thread stall detection. Nothing here leaves the Mac.
public enum LocalDiagnostics {
    /// Runs once: `LoggingSystem.bootstrap` may only be called a single time.
    private static let started: Void = {
        LoggingSystem.bootstrap { label in
            var systemHandler = UnifiedLogHandler(label: label)
            systemHandler.logLevel = .info
            return MultiplexLogHandler([systemHandler, LocalDiagnosticLogHandler(label: label)])
        }
        MainThreadHealthMonitor.shared.start()
        DispatchQueue.main.async { InteractionDiagnosticMonitor.shared.start() }
        let lifecycle = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
        lifecycle.info("Application diagnostics started", metadata: ["event": "app_started"])
    }()

    public static func start() {
        _ = started
    }

    /// Marks an audio capture (e.g. "dictation", "meeting") as running so stall
    /// diagnostics don't spawn `sample`, which suspends every thread in the process.
    public static func setAudioCaptureActive(_ active: Bool, source: String) {
        MainThreadHealthMonitor.shared.setAudioCaptureActive(active, source: source)
    }
}

private struct UnifiedLogHandler: LogHandler {
    private let logger: os.Logger

    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?
    var logLevel: Logging.Logger.Level = .info

    init(label: String) {
        logger = os.Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "agency.thatworks.WhiskerFlow",
            category: label
        )
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combinedMetadata = metadata
        if let providerMetadata = metadataProvider?.get() {
            combinedMetadata.merge(providerMetadata) { _, new in new }
        }
        if let explicitMetadata = event.metadata {
            combinedMetadata.merge(explicitMetadata) { _, new in new }
        }
        let fields = combinedMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let rendered = fields.isEmpty
            ? event.message.description
            : "\(event.message.description) \(fields)"

        switch event.level {
        case .trace, .debug:
            logger.debug("\(rendered, privacy: .public)")
        case .info, .notice:
            logger.info("\(rendered, privacy: .public)")
        case .warning:
            logger.warning("\(rendered, privacy: .public)")
        case .error:
            logger.error("\(rendered, privacy: .public)")
        case .critical:
            logger.critical("\(rendered, privacy: .public)")
        }
    }
}
