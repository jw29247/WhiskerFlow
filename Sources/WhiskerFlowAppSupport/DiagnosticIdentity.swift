import Foundation

public struct DiagnosticIdentity: Sendable {
    public static let current = DiagnosticIdentity(defaults: .standard)
    public let installationID: String
    public let launchID: String
    public let build: String

    init(defaults: UserDefaults) {
        let key = "diagnostics.installationID"
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) {
            installationID = id.uuidString
        } else {
            installationID = UUID().uuidString
            defaults.set(installationID, forKey: key)
        }
        launchID = UUID().uuidString
        build = Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowBuildRevision") as? String ?? "development"
    }
}
