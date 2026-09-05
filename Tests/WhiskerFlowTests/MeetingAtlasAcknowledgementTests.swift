import XCTest
@testable import WhiskerFlow

final class MeetingAtlasAcknowledgementTests: XCTestCase {
    func testIncompletePlaybackIsNotSuccess() async throws {
        do { try await client(host: "incomplete.test").completePlayback(artifactID: "fixture"); XCTFail("Must retain local recording") }
        catch MeetingAtlasClientError.server {}
    }
    func testDuplicatePlaybackAcknowledgementIsAccepted() async throws {
        try await client(host: "duplicate.test").completePlayback(artifactID: "fixture")
    }
    func testMissingFinalizationAcknowledgementIsNotSuccess() async throws {
        do { try await client(host: "invalid.test").finalize(meetingID: "fixture", artifactID: "fixture", transcriptionState: "completed", status: "done"); XCTFail("Must retain local recording") }
        catch MeetingAtlasClientError.invalidResponse {}
    }
    private func client(host: String) -> URLSessionMeetingAtlasClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AcknowledgementStub.self]
        return URLSessionMeetingAtlasClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: URLSession(configuration: config))
    }
}
private final class AcknowledgementStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value: [String: Any] = request.url!.host == "invalid.test" ? [:] : ["completed": false, "duplicate": request.url!.host == "duplicate.test"]
        let bytes = try! JSONSerialization.data(withJSONObject: ["ok": true, "value": value])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
