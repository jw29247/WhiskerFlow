import Foundation
import WhiskerFlowAppSupport

protocol AssistantAtlasTransport: Sendable {
    func call(operation: String, arguments: Data) async throws -> Data
}

struct AssistantAtlasClient: AssistantAtlasTransport {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func call(operation: String, arguments: Data) async throws -> Data {
        guard baseURL.scheme == "https" || ["localhost", "127.0.0.1"].contains(baseURL.host ?? "") else {
            throw AssistantError.message("Atlas requires a secure connection.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/notetaker"), timeoutInterval: 14)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int64(Date().timeIntervalSince1970 * 1000)), forHTTPHeaderField: "x-request-timestamp")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tool": "notetaker.assistant.\(operation)",
            "args": try JSONSerialization.jsonObject(with: arguments)
        ])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AssistantError.message("Atlas returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401, 403: throw AssistantError.message("Reconnect Atlas to continue. Your local draft is safe.")
            case 429: throw AssistantError.message("Atlas's request limit was reached. Try again later.")
            default: throw AssistantError.message("Atlas could not complete this request. Try again later.")
            }
        }
        guard data.count <= 1_048_576,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["ok"] as? Bool == true, let value = envelope["value"] else {
            throw AssistantError.message("Atlas could not complete this request. Your local copy is safe.")
        }
        return try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    }
}

enum AssistantError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct AssistantClientProfile: Codable, Identifiable, Equatable {
    var reference: String
    var name: String
    var id: String { reference }
}
struct AssistantCoachResult: Codable, Equatable {
    struct Evidence: Codable, Equatable { var segmentIndex: Int; var quote: String; var startMs: Double }
    struct Suggestion: Codable, Equatable { var text: String; var evidence: [Evidence] }
    var kind: String
    var phase: String
    var title: String
    var suggestions: [Suggestion]
    var incomplete: Bool
}
