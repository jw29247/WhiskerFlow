import Foundation

/// One call to a tool on Atlas's notetaker endpoint, authorised by this Mac's
/// device token. Each client maps the reply to its own errors.
struct AtlasNotetakerRequest: Sendable {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    struct Reply {
        let status: Int
        let envelope: [String: Any]?

        /// The `value` of an `{"ok": true, "value": …}` reply, or nil when Atlas refused.
        var value: Any? {
            guard (200..<300).contains(status), envelope?["ok"] as? Bool == true else { return nil }
            return envelope?["value"]
        }

        var errorCode: String? { envelope?["error"] as? String }
    }

    func send(tool: String, args: [String: Any]) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/notetaker"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "args": args])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int(Date().timeIntervalSince1970 * 1_000)), forHTTPHeaderField: "x-request-timestamp")
        let (body, response) = try await session.data(for: request)
        return Reply(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            envelope: try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}
