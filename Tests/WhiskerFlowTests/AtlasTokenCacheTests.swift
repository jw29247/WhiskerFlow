import Foundation
import Security
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport

/// A Keychain that answers with scripted statuses, then the token.
private final class ScriptedKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [OSStatus]
    private var calls = 0

    init(_ statuses: [OSStatus]) { self.statuses = statuses }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func copyMatching(_ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let status = statuses.isEmpty ? errSecSuccess : statuses.removeFirst()
        if status == errSecSuccess { result?.pointee = Data("device-token".utf8) as CFData }
        return status
    }
}

@MainActor
final class AtlasTokenCacheTests: XCTestCase {
    private func settings(_ keychain: ScriptedKeychain) -> AppSettings {
        let name = "AtlasTokenCacheTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(
            service: name, copyMatching: { _, result in keychain.copyMatching(result) }
        ))
    }

    func testLookupTellsAFailedReadFromAMissingToken() {
        func lookup(_ status: OSStatus) -> MeetingCaptureTokenLookup {
            let keychain = ScriptedKeychain([status])
            return MeetingCaptureTokenStore(service: "fixture", copyMatching: { _, result in keychain.copyMatching(result) }).lookup()
        }
        XCTAssertEqual(lookup(errSecSuccess), .found("device-token"))
        XCTAssertEqual(lookup(errSecItemNotFound), .missing)
        XCTAssertEqual(lookup(errSecUserCanceled), .denied)
        XCTAssertEqual(lookup(errSecInteractionNotAllowed), .unavailable(errSecInteractionNotAllowed))
    }

    func testFailedKeychainReadIsRetriedInsteadOfCachedAsSignedOut() {
        let keychain = ScriptedKeychain([errSecInteractionNotAllowed])
        let settings = settings(keychain)
        let before = keychain.callCount
        XCTAssertEqual(settings.atlasDeviceToken, "", "A locked Keychain reads as signed out for now")
        XCTAssertEqual(settings.atlasDeviceToken, "device-token", "The next read recovers the sign-in")
        XCTAssertEqual(settings.atlasDeviceToken, "device-token")
        XCTAssertEqual(keychain.callCount - before, 2, "A definite answer is cached")
    }

    func testMissingOrDeclinedTokenIsCached() {
        for status in [errSecItemNotFound, errSecUserCanceled] {
            let keychain = ScriptedKeychain([status])
            let settings = settings(keychain)
            let before = keychain.callCount
            XCTAssertEqual(settings.atlasDeviceToken, "")
            XCTAssertEqual(settings.atlasDeviceToken, "", "Not read, or prompted for, again")
            XCTAssertEqual(keychain.callCount - before, 1)
        }
    }
}
