import Foundation
import WhiskerFlowCore

enum LeaderboardClientError: LocalizedError, Equatable {
    case notPermitted
    case unavailable
    case notDeployed
    case rateLimited
    case signedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted: return "Your Atlas account doesn't have WhiskerFlow access yet. Ask an Atlas admin to turn it on."
        case .unavailable: return "The leaderboard is unavailable right now. Try again shortly."
        case .notDeployed: return "Atlas doesn't have the leaderboard yet."
        case .rateLimited: return "Atlas is busy. The leaderboard will refresh shortly."
        case .signedOut: return "Sign in with Atlas to see the leaderboard."
        case .failed(let message): return message
        }
    }
}

/// The two leaderboard tools on Atlas's notetaker endpoint. Only counts are
/// sent; Atlas resolves who you are from the device token.
struct LeaderboardAtlasClient: Sendable {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func report(_ days: [LeaderboardDay]) async throws -> Int {
        let value = try await call(tool: "notetaker.leaderboard.report", args: ["days": days.map(\.payload)])
        return (value as? [String: Any])?["accepted"] as? Int ?? 0
    }

    func board(today: LocalDay, since: LocalDay?) async throws -> LeaderboardBoard {
        var args: [String: Any] = ["today": today.key]
        if let since { args["since"] = since.key }
        let value = try await call(tool: "notetaker.leaderboard.get", args: args)
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(LeaderboardBoard.self, from: data)
    }

    private func call(tool: String, args: [String: Any]) async throws -> Any {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/notetaker"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "args": args])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int(Date().timeIntervalSince1970 * 1_000)), forHTTPHeaderField: "x-request-timestamp")
        let (body, response) = try await session.data(for: request)
        let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), envelope?["ok"] as? Bool == true, let value = envelope?["value"] {
            return value
        }
        throw Self.error(status: status, code: envelope?["error"] as? String)
    }

    static func error(status: Int, code: String?) -> LeaderboardClientError {
        switch (status, code) {
        case (_, "leaderboard_not_permitted"): return .notPermitted
        case (_, "leaderboard_rate_limited"), (429, _): return .rateLimited
        case (401, _): return .signedOut
        case (503, _), (_, "leaderboard_unavailable"): return .unavailable
        // An Atlas without the tools rejects them as unknown.
        case (400, let code?) where !code.hasPrefix("leaderboard_invalid"): return .notDeployed
        case (403, _): return .notPermitted
        default: return .failed("Atlas couldn't load the leaderboard (HTTP \(status)).")
        }
    }
}
