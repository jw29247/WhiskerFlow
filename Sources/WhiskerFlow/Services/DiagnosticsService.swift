import Foundation
import Logging
import WhiskerFlowAppSupport

/// Records failures and lifecycle breadcrumbs on this Mac only: the unified
/// system log and `~/Library/Logs/WhiskerFlow/diagnostics.jsonl`. Only an
/// allow-listed category, an error code and allow-listed metadata are written;
/// error descriptions never are.
enum DiagnosticsService {
    private static let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.Diagnostics"
    )

    static func breadcrumb(category: String, metadata: [String: String] = [:]) {
        guard DiagnosticPrivacy.allowsCategory(category) else { return }
        var fields = DiagnosticPrivacy.safeMetadata(from: metadata)
        fields["event"] = "diagnostic_breadcrumb"
        fields["category"] = category
        logger.info("Diagnostic breadcrumb", metadata: fields.mapValues { .string($0) })
    }

    static func capture(error: Error, category: String, code: String? = nil) {
        guard DiagnosticPrivacy.allowsCategory(category) else { return }
        var fields = DiagnosticPrivacy.safeMetadata(from: code.map { ["error_code": $0] } ?? [:])
        fields["event"] = "diagnostic_error"
        fields["category"] = category
        logger.error("Diagnostic error", metadata: fields.mapValues { .string($0) })
    }
}
