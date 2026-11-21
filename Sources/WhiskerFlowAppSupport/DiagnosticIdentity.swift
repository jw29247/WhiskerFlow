import Foundation

/// Identifies the running process in local diagnostic rows. It is not
/// persisted: each launch gets a new ID.
public struct DiagnosticIdentity: Sendable {
    public static let current = DiagnosticIdentity()
    public let launchID: String
    public let build: String

    init() {
        launchID = UUID().uuidString
        build = Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowBuildRevision") as? String ?? "development"
    }
}
