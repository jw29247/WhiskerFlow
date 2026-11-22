import Foundation
import Security
import WhiskerFlowAppSupport

/// Generic-password items kept in memory for the life of the test process,
/// keyed by service and account like the real Keychain, so two settings made
/// with the same service still share one token.
private final class InMemoryKeychainItems: @unchecked Sendable {
    static let shared = InMemoryKeychainItems()

    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private static func key(_ query: CFDictionary) -> String {
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return service + "\u{0}" + account
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.withLock {
            guard let data = items[Self.key(query)] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let key = Self.key(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = (attributes as NSDictionary)[kSecValueData as String] as? Data ?? Data()
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            let key = Self.key(query)
            guard items[key] != nil else { return errSecItemNotFound }
            items[key] = (attributes as NSDictionary)[kSecValueData as String] as? Data ?? Data()
            return errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            items.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

extension MeetingCaptureTokenStore {
    /// A token store that never reaches the login Keychain. Tests use this in
    /// place of `MeetingCaptureTokenStore(service:)`, which reads and writes
    /// real Keychain items.
    static func inMemory(service: String) -> MeetingCaptureTokenStore {
        let items = InMemoryKeychainItems.shared
        return MeetingCaptureTokenStore(
            service: service,
            copyMatching: { items.copyMatching($0, $1) },
            addItem: { items.add($0) },
            updateItem: { items.update($0, $1) },
            deleteItem: { items.delete($0) }
        )
    }
}
