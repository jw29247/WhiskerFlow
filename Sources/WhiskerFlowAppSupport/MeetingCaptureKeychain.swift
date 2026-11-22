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
    public typealias Add = @Sendable (CFDictionary) -> OSStatus
    public typealias Update = @Sendable (CFDictionary, CFDictionary) -> OSStatus
    public typealias Delete = @Sendable (CFDictionary) -> OSStatus

    private let service: String
    private let account: String
    private let copyMatching: CopyMatching
    private let addItem: Add
    private let updateItem: Update
    private let deleteItem: Delete

    /// - Parameters:
    ///   - copyMatching: the Keychain query; tests inject failures.
    ///   - addItem, updateItem, deleteItem: the Keychain writes; tests inject
    ///     an in-memory Keychain so sign-in and sign-out never touch a real item.
    public init(
        service: String = "agency.thatworks.WhiskerFlow.meeting-capture",
        account: String = "atlas-device-token",
        copyMatching: @escaping CopyMatching = { SecItemCopyMatching($0, $1) },
        addItem: @escaping Add = { SecItemAdd($0, nil) },
        updateItem: @escaping Update = { SecItemUpdate($0, $1) },
        deleteItem: @escaping Delete = { SecItemDelete($0) }
    ) {
        self.service = service
        self.account = account
        self.copyMatching = copyMatching
        self.addItem = addItem
        self.updateItem = updateItem
        self.deleteItem = deleteItem
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
        let status = updateItem(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = addItem(add as CFDictionary)
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
        let status = deleteItem(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeetingCaptureKeychainError.status(status)
        }
    }
}

public enum MeetingCaptureKeychainError: Error, Equatable {
    case status(OSStatus)
}
