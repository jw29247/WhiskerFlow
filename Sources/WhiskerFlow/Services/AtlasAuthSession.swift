import AuthenticationServices
import AppKit
import Foundation

enum AtlasAuthSessionError: LocalizedError {
    case invalidBaseURL
    case cancelled
    case invalidCallback
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Enter a valid Atlas HTTPS URL first."
        case .cancelled: return "Atlas sign-in was cancelled."
        case .invalidCallback: return "Atlas returned an invalid sign-in response."
        case .missingToken: return "Atlas did not return a device connection token."
        }
    }
}

@MainActor
final class AtlasAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func connect(baseURLString: String) async throws -> String {
        guard let baseURL = URL(string: baseURLString), baseURL.scheme == "https" else {
            throw AtlasAuthSessionError.invalidBaseURL
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("whiskerflow/connect"),
            resolvingAgainstBaseURL: false
        )
        let state = UUID().uuidString
        components?.queryItems = [
            URLQueryItem(name: "callback", value: "whiskerflow://auth/callback"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw AtlasAuthSessionError.invalidBaseURL }

        return try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "whiskerflow"
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        ? AtlasAuthSessionError.cancelled
                        : error)
                    return
                }
                guard let callbackURL,
                      callbackURL.host == "auth",
                      callbackURL.path == "/callback",
                      let fragment = callbackURL.fragment,
                      let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems,
                      fragmentItems.first(where: { $0.name == "state" })?.value == state,
                      let token = fragmentItems.first(where: { $0.name == "token" })?.value,
                      token.hasPrefix("twnt_"), token.count > 20 else {
                    continuation.resume(throwing: AtlasAuthSessionError.invalidCallback)
                    return
                }
                continuation.resume(returning: token)
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            self.session = authSession
            guard authSession.start() else {
                self.session = nil
                continuation.resume(throwing: AtlasAuthSessionError.invalidCallback)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
