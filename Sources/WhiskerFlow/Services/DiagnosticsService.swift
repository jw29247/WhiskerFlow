import Foundation
import OSLog
import Sentry
import WhiskerFlowAppSupport

enum DiagnosticsService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.thatworks.WhiskerFlow",
        category: "Diagnostics"
    )

    static func start() {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowSentryDSN") as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("Sentry disabled because no DSN is configured")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
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
    }

    static func breadcrumb(category: String, metadata: [String: String] = [:]) {
        guard DiagnosticPrivacy.allowsBreadcrumb(category: category) else { return }
        let breadcrumb = Breadcrumb(level: .info, category: category)
        breadcrumb.data = DiagnosticPrivacy.safeMetadata(from: metadata)
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func capture(error: Error, category: String, code: String? = nil) {
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

        event.threads?.forEach { thread in
            thread.name = nil
            redact(thread.stacktrace)
        }
        event.exceptions?.forEach { exception in
            // Exception values can include framework assertions, paths, device
            // identifiers, or other runtime content. The type and mechanism
            // retain the crash classification without that payload.
            exception.value = nil
            exception.module = nil
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
            frame.package = nil
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
