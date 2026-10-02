import Foundation
import Security

/// What a token lookup found. Only `unavailable` is uncertain: a locked
/// Keychain or a busy securityd says nothing about whether the token exists.
public enum MeetingCaptureTokenLookup: Equatable, Sendable {
    case found(String)
    case missing
    /// The user declined the Keychain's prompt to allow access.
    case denied
    case unavailable(OSStatus)
}

public final class MeetingCaptureTokenStore: @unchecked Sendable {
    public typealias CopyMatching = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    private let service: String
    private let account: String
    private let copyMatching: CopyMatching

    /// - Parameter copyMatching: the Keychain query; tests inject failures.
    public init(
        service: String = "agency.thatworks.WhiskerFlow.meeting-capture",
        account: String = "atlas-device-token",
        copyMatching: @escaping CopyMatching = { SecItemCopyMatching($0, $1) }
    ) {
        self.service = service
        self.account = account
        self.copyMatching = copyMatching
    }

    public func lookup() -> MeetingCaptureTokenLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return .missing }
            return .found(token)
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        default:
            return .unavailable(status)
        }
    }

    /// The token, or `nil` when it is missing or the Keychain can't be read.
    public func read() -> String? {
        guard case .found(let token) = lookup() else { return nil }
        return token
    }

    public func write(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MeetingCaptureKeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw MeetingCaptureKeychainError.status(status)
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeetingCaptureKeychainError.status(status)
        }
    }
}

public enum MeetingCaptureKeychainError: Error, Equatable {
    case status(OSStatus)
}
