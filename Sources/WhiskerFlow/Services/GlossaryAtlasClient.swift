import Foundation

enum GlossaryClientError: LocalizedError, Equatable {
    case signedOut
    case notPermitted
    case notDeployed
    case rateLimited
    case unavailable
    case invalidResponse
    case failed(status: Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in with Atlas to update the shared glossary."
        case .notPermitted: return "Your Atlas account can't read the shared glossary."
        case .notDeployed: return "Atlas doesn't serve the shared glossary yet."
        case .rateLimited: return "Atlas is busy. The shared glossary will update later."
        case .unavailable: return "The shared glossary is unavailable right now."
        case .invalidResponse: return "Atlas returned an unreadable glossary."
        case .failed(let status): return "Atlas couldn't load the shared glossary (HTTP \(status))."
        }
    }

    /// Signed out and "tool not deployed yet" are expected states, not faults.
    var isReportable: Bool {
        switch self {
        case .signedOut, .notDeployed: return false
        default: return true
        }
    }

    var diagnosticCode: String {
        switch self {
        case .signedOut: return "signed_out"
        case .notPermitted: return "not_permitted"
        case .notDeployed: return "not_deployed"
        case .rateLimited: return "rate_limited"
        case .unavailable: return "unavailable"
        case .invalidResponse: return "invalid_response"
        case .failed(let status): return "http_\(status)"
        }
    }

    static func error(status: Int, code: String?) -> GlossaryClientError {
        switch (status, code) {
        case (401, _): return .signedOut
        case (403, _): return .notPermitted
        case (429, _): return .rateLimited
        case (500..<600, _): return .unavailable
        // An Atlas without the tool rejects it as unknown, as it does for the leaderboard.
        case (400, _?): return .notDeployed
        default: return .failed(status: status)
        }
    }
}

/// Reads the agency glossary from Atlas's notetaker endpoint. The request
/// carries no arguments: no transcript or user data is sent, and Atlas knows
/// the caller from the device token.
struct GlossaryAtlasClient: Sendable {
    static let tool = "notetaker.glossary.get"

    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    /// The glossary as `{"rules": […]}` JSON, the same shape as a local
    /// `Vocabulary`, ready for the same validation as the on-disk cache.
    func fetch() async throws -> Data {
        let reply = try await AtlasNotetakerRequest(baseURL: baseURL, token: token, session: session)
            .send(tool: Self.tool, args: [:])
        guard let value = reply.value else {
            throw GlossaryClientError.error(status: reply.status, code: reply.errorCode)
        }
        guard let glossary = value as? [String: Any] else { throw GlossaryClientError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: glossary)
    }
}
