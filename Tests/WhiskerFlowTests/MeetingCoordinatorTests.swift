import XCTest
import CryptoKit
@testable import WhiskerFlow
import WhiskerFlowAppSupport

final class MeetingCoordinatorTests: XCTestCase {
    @MainActor
    func testDisconnectedPreferredMicrophoneFallsBackToSystemDefault() {
        XCTAssertEqual(MeetingAudioCaptureService.availableMicrophoneSelection(.device(uid: "unplugged"), availableUIDs: ["built-in"]), .systemDefault)
        XCTAssertEqual(MeetingAudioCaptureService.availableMicrophoneSelection(.device(uid: "connected"), availableUIDs: ["connected"]), .device(uid: "connected"))
    }

    @MainActor
    func testManualModeStillLoadsAtlasCalendarWithoutStartingCapture() async {
        let name = "MeetingCoordinatorTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.meetingModeEnabled = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeetingScheduleStub.self]
        let client = URLSessionMeetingAtlasClient(baseURL: URL(string: "https://atlas.test")!, token: "fixture", session: URLSession(configuration: config))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MeetingCaptureCoordinator(settings: settings, microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()), transcription: TranscriptionService(), store: EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))), clientProvider: { client })
        await coordinator.pollSchedule()
        XCTAssertEqual(coordinator.scheduleIntents.count, 1, "Manual recording must not hide the Atlas calendar")
        XCTAssertFalse(coordinator.isCapturing)
    }
}

private final class MeetingScheduleStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body = try! JSONSerialization.data(withJSONObject: ["ok": true, "value": [["eventId": "fixture", "title": "Fixture", "startMs": now, "endMs": now + 600000, "meetingUrl": "https://meet.google.com/abc-defg-hij"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
