import Foundation
import Logging
import Sentry
import WhiskerFlowAppSupport

enum DiagnosticsService {
    private static let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.Diagnostics"
    )

    static func start() {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowSentryDSN") as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("Sentry disabled because no DSN is configured")
            return
        }
        let verificationRequested = CommandLine.arguments.contains("--verify-sentry")

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = verificationRequested
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            // Sessions carry only app version and OS, and without them Sentry
            // cannot compute a crash-free rate.
            options.enableAutoSessionTracking = true
            options.enableMetrics = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoBreadcrumbTracking = false
            options.enableLogs = false
            options.maxBreadcrumbs = 30
            options.enableAppHangTracking = true
            options.beforeBreadcrumb = { breadcrumb in
                guard DiagnosticPrivacy.allowsBreadcrumb(category: breadcrumb.category) else {
                    return nil
                }
                breadcrumb.message = nil
                if let values = breadcrumb.data as? [String: String] {
                    breadcrumb.data = DiagnosticPrivacy.safeMetadata(from: values)
                } else {
                    breadcrumb.data = nil
                }
                return breadcrumb
            }
            options.beforeSend = { event in
                redact(event)
            }
        }
        logger.info("Sentry crash reporting enabled with privacy filters")
        if verificationRequested {
            capture(
                error: SanitizedDiagnosticError(category: "model", code: "verification"),
                category: "model",
                code: "verification"
            )
            SentrySDK.flush(timeout: 5)
            logger.info("Sentry verification event flushed")
        }
    }

    static func breadcrumb(category: String, metadata: [String: String] = [:]) {
        guard SentrySDK.isEnabled else { return }
        guard DiagnosticPrivacy.allowsBreadcrumb(category: category) else { return }
        let breadcrumb = Breadcrumb(level: .info, category: category)
        breadcrumb.data = DiagnosticPrivacy.safeMetadata(from: metadata)
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func capture(error: Error, category: String, code: String? = nil) {
        guard SentrySDK.isEnabled else { return }
        breadcrumb(
            category: category,
            metadata: code.map { ["error_code": $0] } ?? [:]
        )
        SentrySDK.capture(error: SanitizedDiagnosticError(category: category, code: code))
    }

    private static func redact(_ event: Event) -> Event {
        event.message = nil
        event.error = nil
        event.user = nil
        event.request = nil
        event.extra = nil
        event.context = nil
        event.modules = nil
        event.fingerprint = nil
        event.serverName = nil
        event.logger = nil
        event.transaction = nil
        event.tags = nil
        event.debugMeta?.forEach { image in
            image.codeFile = DiagnosticPrivacy.safeDebugImageName(image.codeFile)
        }

        event.threads?.forEach { thread in
            thread.name = nil
            redact(thread.stacktrace)
        }
        event.exceptions?.forEach { exception in
            // Exception values can include paths, device identifiers, or other
            // runtime content. Sanitizing rather than clearing keeps the
            // assertion text that identifies the crash. The module is a
            // framework name, not user content.
            exception.value = DiagnosticPrivacy.sanitizedCrashText(exception.value)
            redact(exception.stacktrace)
        }
        redact(event.stacktrace)

        event.breadcrumbs = event.breadcrumbs?.compactMap { breadcrumb in
            guard DiagnosticPrivacy.allowsBreadcrumb(category: breadcrumb.category) else {
                return nil
            }
            breadcrumb.message = nil
            if let values = breadcrumb.data as? [String: String] {
                breadcrumb.data = DiagnosticPrivacy.safeMetadata(from: values)
            } else {
                breadcrumb.data = nil
            }
            return breadcrumb
        }
        return event
    }

    private static func redact(_ stacktrace: SentryStacktrace?) {
        stacktrace?.frames.forEach { frame in
            frame.fileName = nil
            // The binary basename is what Sentry groups on; the containing path
            // is the part that can carry a user directory.
            frame.package = DiagnosticPrivacy.safeDebugImageName(frame.package)
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }
}

private struct SanitizedDiagnosticError: LocalizedError {
    let category: String
    let code: String?

    var errorDescription: String? {
        code.map { "\(category) error (\($0))" } ?? "\(category) error"
    }
}
