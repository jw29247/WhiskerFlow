import XCTest
import WhiskerFlowAppSupport
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
    func testMeetAndManualNamesPreserveTheirSourceInUpload() async throws {
        let meet = try JSONDecoder().decode(MeetingSpeakerIdentity.self, from: Data(#"{"key":"meet-fixture","displayName":"Fixture Person","resolution":"google_meet"}"#.utf8))
        try await client(host: "provenance.test").appendSegments(meetingID: "fixture", turns: [
            MeetingSpeakerTurn(startMs: 0, endMs: 1000, text: "Fixture speech", speaker: meet),
            MeetingSpeakerTurn(startMs: 1000, endMs: 2000, text: "Other fixture", speaker: .manual(key: "manual-fixture", displayName: "Other Person")),
        ])
    }
    func testSegmentIdempotencyIsScopedToTheRecordingArtifact() async throws {
        AcknowledgementStub.externalRefs = []
        let turn = MeetingSpeakerTurn(startMs: 0, endMs: 1000, text: "Fixture speech", speaker: .microphone)
        try await client(host: "segmentref.test").appendSegments(meetingID: "shared-meeting", artifactID: "artifact-a", turns: [turn])
        try await client(host: "segmentref.test").appendSegments(meetingID: "shared-meeting", artifactID: "artifact-b", turns: [turn])
        XCTAssertEqual(AcknowledgementStub.externalRefs, ["segments-artifact-a-0", "segments-artifact-b-0"])
    }
    private func client(host: String) -> URLSessionMeetingAtlasClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AcknowledgementStub.self]
        return URLSessionMeetingAtlasClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: URLSession(configuration: config))
    }
}
private final class AcknowledgementStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var externalRefs: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "provenance.test" || request.url?.host == "segmentref.test" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let args = envelope?["args"] as? [String: Any]
            let segments = args?["segments"] as? [[String: Any]] ?? []
            if request.url?.host == "segmentref.test" {
                Self.externalRefs.append(args?["externalRef"] as? String ?? "")
            } else {
                XCTAssertEqual(segments.compactMap { $0["speakerResolution"] as? String }, ["unknown", "manual"])
                XCTAssertEqual(segments.compactMap { $0["speakerProvider"] as? String }, ["google_meet", "manual"])
            }
            let bytes = try! JSONSerialization.data(withJSONObject: ["ok": true, "value": ["appended": segments.count]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let value: [String: Any] = request.url!.host == "invalid.test" ? [:] : ["completed": false, "duplicate": request.url!.host == "duplicate.test"]
        let bytes = try! JSONSerialization.data(withJSONObject: ["ok": true, "value": value])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
