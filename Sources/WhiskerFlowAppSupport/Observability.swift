import Foundation
import Logging
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import OSLog
import OTelSwiftLog

public enum TelemetrySignal: String, CaseIterable, Sendable {
    case traces
    case logs
    case metrics
}

public enum Observability {
    private static let endpoint = URL(
        string: "https://proxy-production-1ee1.up.railway.app"
    )!
    private static let publicToken =
        "sl_public_GXIrb2ElYhvKiD55sKioSIHprxB0b1OyFQzwJAdjqfo"
    private static let instrumentationName = "whiskerflow.macos"

    private static let state = State()

    public static var tracer: any Tracer {
        state.tracer
    }

    public static var assistantOperations: LongCounterSdk { state.assistantOperations }

    public static var dictationSessions: LongCounterSdk {
        state.dictationSessions
    }

    public static var transcriptionOperations: LongCounterSdk {
        state.transcriptionOperations
    }

    public static var transcriptionDuration: DoubleHistogramMeterSdk {
        state.transcriptionDuration
    }

    public static var recordingDuration: DoubleHistogramMeterSdk {
        state.recordingDuration
    }

    public static var transcriptPersistence: LongCounterSdk {
        state.transcriptPersistence
    }

    public static func start() {
        guard state.markStarted() else { return }

        state.tracer.spanBuilder(spanName: "app.start").withActiveSpan { span in
            span.setAttribute(key: "app.lifecycle.phase", value: "started")
            span.status = .ok
            state.appLifecycle.add(
                value: 1,
                attributes: [
                    "phase": .string("started"),
                    "outcome": .string("success")
                ]
            )
            let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.Observability")
            logger.info(
                "OpenTelemetry initialized",
                metadata: [
                    "deployment.environment.name": "\(state.environmentName)",
                    "telemetry.endpoint.host": "\(endpoint.host ?? "unknown")"
                ]
            )
        }
    }

    @discardableResult
    public static func forceFlush(timeout: TimeInterval = 5) -> [TelemetrySignal: Int] {
        state.spanProcessor.forceFlush(timeout: timeout)
        state.logProcessor.forceFlush(timeout: timeout)
        _ = state.meterProvider.forceFlush()
        _ = state.requests.wait(timeout: .now() + timeout)
        return state.statuses.snapshot()
    }

    public static func shutdown(timeout: TimeInterval = 5) {
        _ = forceFlush(timeout: timeout)
        state.spanProcessor.shutdown(explicitTimeout: timeout)
        _ = state.logProcessor.shutdown(explicitTimeout: timeout)
        _ = state.meterProvider.shutdown()
        _ = state.requests.wait(timeout: .now() + timeout)
    }

    /// Emits one record for every signal and returns the observed OTLP response
    /// codes. Intended for the opt-in live smoke test.
    public static func verify(timeout: TimeInterval = 10) -> [TelemetrySignal: Int] {
        start()
        state.statuses.reset()

        state.tracer.spanBuilder(spanName: "telemetry.verify").withActiveSpan { span in
            span.setAttribute(key: "telemetry.smoke", value: true)
            span.status = .ok

            state.telemetryVerification.add(
                value: 1,
                attributes: ["outcome": .string("success")]
            )
            let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.TelemetrySmoke")
            logger.info(
                "Telemetry verification emitted",
                metadata: ["telemetry.smoke": "true"]
            )
        }

        return forceFlush(timeout: timeout)
    }

    private static func superlogHeaders(_ token: String) -> [(String, String)] {
        [("x-api-key", token)]
    }

    private final class State {
        let statuses = ExportStatusStore()
        let requests = DispatchGroup()
        let environmentName: String
        let spanProcessor: BatchSpanProcessor
        let logProcessor: BatchLogRecordProcessor
        let meterProvider: MeterProviderSdk
        let tracer: any Tracer
        let appLifecycle: LongCounterSdk
        let assistantOperations: LongCounterSdk
        let dictationSessions: LongCounterSdk
        let transcriptionOperations: LongCounterSdk
        let transcriptionDuration: DoubleHistogramMeterSdk
        let recordingDuration: DoubleHistogramMeterSdk
        let transcriptPersistence: LongCounterSdk
        let telemetryVerification: LongCounterSdk

        private let startLock = NSLock()
        private var started = false

        init() {
            environmentName = Self.resolveEnvironmentName()
            let resource = Self.makeResource(environmentName: environmentName)
            let headers = Observability.superlogHeaders(Observability.publicToken)
            let config = OtlpConfiguration(
                timeout: 10,
                compression: .gzip,
                headers: headers,
                exportAsJson: false
            )

            let metricExporter = OtlpHttpMetricExporter(
                endpoint: Observability.endpoint.appendingPathComponent("v1/metrics"),
                config: config,
                httpClient: StatusRecordingHTTPClient(
                    signal: .metrics,
                    statuses: statuses,
                    requests: requests
                ),
                envVarHeaders: headers
            )
            let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
                .setInterval(timeInterval: 15)
                .build()
            meterProvider = MeterProviderSdk.builder()
                .setResource(resource: resource)
                .registerMetricReader(reader: metricReader)
                .registerView(
                    selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                    view: View.builder().build()
                )
                .build()

            let traceExporter = OtlpHttpTraceExporter(
                endpoint: Observability.endpoint.appendingPathComponent("v1/traces"),
                config: config,
                httpClient: StatusRecordingHTTPClient(
                    signal: .traces,
                    statuses: statuses,
                    requests: requests
                ),
                envVarHeaders: headers
            )
            spanProcessor = BatchSpanProcessor(
                spanExporter: traceExporter,
                scheduleDelay: 5,
                exportTimeout: 10
            )
            let tracerProvider = TracerProviderBuilder()
                .with(resource: resource)
                .add(spanProcessor: spanProcessor)
                .build()

            let logExporter = OtlpHttpLogExporter(
                endpoint: Observability.endpoint.appendingPathComponent("v1/logs"),
                config: config,
                httpClient: StatusRecordingHTTPClient(
                    signal: .logs,
                    statuses: statuses,
                    requests: requests
                ),
                envVarHeaders: headers
            )
            logProcessor = BatchLogRecordProcessor(
                logRecordExporter: logExporter,
                scheduleDelay: 5,
                exportTimeout: 10
            )
            let loggerProvider = LoggerProviderBuilder()
                .with(resource: resource)
                .with(processors: [logProcessor])
                .build()

            OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
            OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
            OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

            tracer = tracerProvider.get(
                instrumentationName: Observability.instrumentationName,
                instrumentationVersion: Self.serviceVersion()
            )
            let meter = meterProvider.get(name: Observability.instrumentationName)
            appLifecycle = meter.counterBuilder(name: "app.lifecycle")
                .setDescription("Application lifecycle transitions")
                .setUnit("1")
                .build()
            assistantOperations = meter.counterBuilder(name: "assistant.operations").setDescription("Assistant request outcomes without content").setUnit("1").build()
            dictationSessions = meter.counterBuilder(name: "dictation.sessions")
                .setDescription("Dictation session state transitions")
                .setUnit("1")
                .build()
            transcriptionOperations = meter.counterBuilder(name: "transcription.operations")
                .setDescription("Transcription operation outcomes")
                .setUnit("1")
                .build()
            transcriptionDuration = meter.histogramBuilder(name: "transcription.duration")
                .setDescription("End-to-end transcription duration")
                .setUnit("s")
                .build()
            recordingDuration = meter.histogramBuilder(name: "dictation.recording.duration")
                .setDescription("Captured dictation audio duration")
                .setUnit("s")
                .build()
            transcriptPersistence = meter.counterBuilder(name: "transcript.persistence")
                .setDescription("Transcript persistence outcomes")
                .setUnit("1")
                .build()
            telemetryVerification = meter.counterBuilder(name: "telemetry.verification")
                .setDescription("Live telemetry smoke attempts")
                .setUnit("1")
                .build()

            LoggingSystem.bootstrap { label in
                var otelHandler = OTelLogHandler(
                    loggerProvider: loggerProvider,
                    includeTraceContext: true
                )
                otelHandler.logLevel = .info
                otelHandler.metadata["logger.name"] = .string(label)

                var systemHandler = UnifiedLogHandler(label: label)
                systemHandler.logLevel = .info
                return MultiplexLogHandler([systemHandler, otelHandler])
            }
        }

        func markStarted() -> Bool {
            startLock.lock()
            defer { startLock.unlock() }
            guard !started else { return false }
            started = true
            return true
        }

        private static func makeResource(environmentName: String) -> Resource {
            var attributes: [String: AttributeValue] = [
                "service.name": .string("whiskerflow.macos"),
                "service.version": .string(serviceVersion()),
                "deployment.environment.name": .string(environmentName),
                "vcs.repository.url.full": .string("https://github.com/jw29247/WhiskerFlow")
            ]
            if let revision = vcsRevision() {
                attributes["vcs.ref.head.revision"] = .string(revision)
            }
            return Resource().merging(other: Resource(attributes: attributes))
        }

        private static func serviceVersion() -> String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development"
        }

        private static func resolveEnvironmentName() -> String {
            let environment = ProcessInfo.processInfo.environment
            for key in [
                "RAILWAY_ENVIRONMENT_NAME",
                "APP_ENV",
                "ENVIRONMENT",
                "NODE_ENV"
            ] {
                if let value = environment[key], !value.isEmpty {
                    return value.lowercased()
                }
            }
            return Bundle.main.bundleIdentifier == nil ? "development" : "production"
        }

        private static func vcsRevision() -> String? {
            let environment = ProcessInfo.processInfo.environment
            for key in [
                "RAILWAY_GIT_COMMIT_SHA",
                "GITHUB_SHA",
                "SOURCE_COMMIT",
                "GIT_COMMIT"
            ] {
                if let value = environment[key], !value.isEmpty {
                    return value
                }
            }
            return nil
        }
    }
}

private final class ExportStatusStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TelemetrySignal: Int] = [:]

    func record(_ statusCode: Int, for signal: TelemetrySignal) {
        lock.lock()
        values[signal] = statusCode
        lock.unlock()
    }

    func reset() {
        lock.lock()
        values = [:]
        lock.unlock()
    }

    func snapshot() -> [TelemetrySignal: Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct TelemetryHTTPStatusError: LocalizedError {
    let signal: TelemetrySignal
    let statusCode: Int

    var errorDescription: String? {
        "\(signal.rawValue) export returned HTTP \(statusCode)"
    }
}

private final class StatusRecordingHTTPClient: HTTPClient {
    private let signal: TelemetrySignal
    private let statuses: ExportStatusStore
    private let requests: DispatchGroup
    private let base = BaseHTTPClient()

    init(
        signal: TelemetrySignal,
        statuses: ExportStatusStore,
        requests: DispatchGroup
    ) {
        self.signal = signal
        self.statuses = statuses
        self.requests = requests
    }

    func send(
        request: URLRequest,
        completion: @escaping (Result<HTTPURLResponse, Error>) -> Void
    ) {
        requests.enter()
        base.send(request: request) { [signal, statuses, requests] result in
            defer { requests.leave() }
            switch result {
            case .success(let response):
                statuses.record(response.statusCode, for: signal)
                guard (200..<300).contains(response.statusCode) else {
                    completion(
                        .failure(
                            TelemetryHTTPStatusError(
                                signal: signal,
                                statusCode: response.statusCode
                            )
                        )
                    )
                    return
                }
                completion(.success(response))
            case .failure(let error):
                completion(.failure(error))
            }
        }
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
