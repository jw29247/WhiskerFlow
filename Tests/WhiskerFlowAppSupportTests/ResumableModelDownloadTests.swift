import CryptoKit
import Foundation
import XCTest
@testable import WhiskerFlowAppSupport

final class ResumableModelDownloadTests: XCTestCase {
    private var folder: URL!
    private let source = URL(string: "https://example.invalid/models/model.gguf")!
    private let content = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ResumableModelDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var destination: URL { folder.appendingPathComponent("model.gguf") }

    private func makeDownload(_ transport: FakeTransport, pauses: Recorder<TimeInterval> = Recorder()) -> ResumableModelDownload {
        ResumableModelDownload(source: source, byteCount: Int64(content.count), destination: destination, transport: transport,
                               retryDelays: [1, 2], pause: { pauses.append($0) })
    }

    private func verifier(_ expected: Data) -> @Sendable (URL) throws -> Void {
        let digest = Data(SHA256.hash(data: expected))
        return { url in
            guard Data(SHA256.hash(data: try Data(contentsOf: url))) == digest else { throw VerifyError() }
        }
    }

    private func assertNoPartial(_ download: ResumableModelDownload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.partialFile.path), "partial file left behind", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.partialFile.path + ".json"), "partial record left behind", file: file, line: line)
        XCTAssertEqual(download.resumableBytes, 0, file: file, line: line)
    }

    func testResumesAfterANetworkDropWithTheRightBytes() async throws {
        let transport = FakeTransport([
            .init(status: 200, headers: ["ETag": "\"abc\"", "Content-Length": "1000"], body: content.prefix(400), then: .fail(URLError(.networkConnectionLost))),
            .init(status: 206, headers: ["ETag": "\"abc\"", "Content-Range": "bytes 400-999/1000"], body: content.suffix(600)),
        ])
        let pauses = Recorder<TimeInterval>()
        let download = makeDownload(transport, pauses: pauses)
        try await download.install(verify: verifier(content), progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: destination), content)
        assertNoPartial(download)
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Range"), "bytes=400-")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "If-Range"), "\"abc\"")
        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "Accept-Encoding") }, ["identity", "identity"])
        XCTAssertEqual(pauses.values, [1])
    }

    func testResumesAfterQuittingAndProgressStartsFromTheResumedFraction() async throws {
        // The first run is stopped part-way, as a quit or sleep would.
        let blocked = AsyncStream<Void>.makeStream()
        let first = FakeTransport([
            .init(status: 200, headers: ["ETag": "\"abc\"", "Content-Length": "1000"], body: content.prefix(250), then: .block(blocked.continuation)),
        ])
        let interrupted = makeDownload(first)
        let task = Task { try await interrupted.install(verify: verifier(content), progress: { _ in }) }
        for await _ in blocked.stream { break }
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch {}
        XCTAssertEqual(interrupted.resumableBytes, 250, "quitting must keep the partial file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // A fresh object, as after relaunch, picks up from the same bytes.
        let second = FakeTransport([
            .init(status: 206, headers: ["ETag": "\"abc\"", "Content-Range": "bytes 250-999/1000"], body: content.suffix(750)),
        ])
        let resumed = makeDownload(second)
        XCTAssertEqual(resumed.resumableFraction, 0.25, accuracy: 0.0001)
        let progress = Recorder<Double>()
        try await resumed.install(verify: verifier(content), progress: { progress.append($0) })

        XCTAssertEqual(progress.values.first ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted(), "progress never goes backwards")
        XCTAssertEqual(second.requests[0].value(forHTTPHeaderField: "Range"), "bytes=250-")
        XCTAssertEqual(try Data(contentsOf: destination), content)
        assertNoPartial(resumed)
    }

    func testChangedETagDiscardsThePartialFileAndRestartsFromZero() async throws {
        let replacement = Data(content.reversed())
        try seedPartial(Data(repeating: 0xAA, count: 600), etag: "\"old\"")
        let transport = FakeTransport([
            // A server that ignores If-Range still reports its new ETag.
            .init(status: 206, headers: ["ETag": "\"new\"", "Content-Range": "bytes 600-999/1000"], body: replacement.suffix(400)),
            .init(status: 200, headers: ["ETag": "\"new\"", "Content-Length": "1000"], body: replacement),
        ])
        let download = makeDownload(transport)
        try await download.install(verify: verifier(replacement), progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: destination), replacement, "nothing from the old partial file is kept")
        XCTAssertNil(transport.requests[1].value(forHTTPHeaderField: "Range"))
        assertNoPartial(download)
    }

    func testChangedLastModifiedOrSizeRestartsFromZero() async throws {
        for headers in [["Last-Modified": "Tue, 02 Jan 2024 00:00:00 GMT", "Content-Range": "bytes 600-999/1000"],
                        ["Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT", "Content-Range": "bytes 600-1099/1100"]] {
            try seedPartial(Data(repeating: 0xAA, count: 600), etag: nil, lastModified: "Mon, 01 Jan 2024 00:00:00 GMT")
            let transport = FakeTransport([
                .init(status: 206, headers: headers, body: content.suffix(400)),
                .init(status: 200, headers: ["Content-Length": "1000"], body: content),
            ])
            let download = makeDownload(transport)
            try await download.install(verify: verifier(content), progress: { _ in })
            XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "If-Range"), "Mon, 01 Jan 2024 00:00:00 GMT")
            XCTAssertNil(transport.requests[1].value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(try Data(contentsOf: destination), content)
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testServerReturningTheWholeFileReplacesThePartialFile() async throws {
        // If-Range didn't match, so the server sent the whole (changed) file.
        try seedPartial(Data(repeating: 0xAA, count: 600), etag: "\"old\"")
        let transport = FakeTransport([.init(status: 200, headers: ["ETag": "\"new\"", "Content-Length": "1000"], body: content)])
        let download = makeDownload(transport)
        try await download.install(verify: verifier(content), progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), content)
    }

    func testARemoteWithADifferentSizeIsRefused() async throws {
        let transport = FakeTransport([.init(status: 200, headers: ["Content-Length": "999"], body: content.prefix(999))])
        let download = makeDownload(transport)
        do {
            try await download.install(verify: verifier(content), progress: { _ in })
            XCTFail("expected a size error")
        } catch let error as ResumableModelDownloadError {
            XCTAssertEqual(error, .unexpectedSize)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCorruptResultFailsVerificationAndLeavesNothingInstalled() async throws {
        var corrupt = content
        corrupt[500] ^= 0xFF
        let transport = FakeTransport([.init(status: 200, headers: ["Content-Length": "1000"], body: corrupt)])
        let download = makeDownload(transport)
        do {
            try await download.install(verify: verifier(content), progress: { _ in })
            XCTFail("expected verification to fail")
        } catch let error as ResumableModelDownloadError {
            XCTAssertEqual(error, .verificationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        assertNoPartial(download)
    }

    func testCorruptReplacementLeavesTheInstalledModelUntouched() async throws {
        try Data("installed".utf8).write(to: destination)
        let transport = FakeTransport([.init(status: 200, headers: ["Content-Length": "1000"], body: Data(repeating: 1, count: 1000))])
        let download = makeDownload(transport)
        do { try await download.install(verify: verifier(content), progress: { _ in }) } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("installed".utf8))
        assertNoPartial(download)
    }

    func testCancellingRemovesThePartialFile() async throws {
        let blocked = AsyncStream<Void>.makeStream()
        let transport = FakeTransport([
            .init(status: 200, headers: ["Content-Length": "1000"], body: content.prefix(300), then: .block(blocked.continuation)),
        ])
        let download = makeDownload(transport)
        let task = Task { try await download.install(verify: verifier(content), progress: { _ in }) }
        for await _ in blocked.stream { break }
        XCTAssertEqual(download.resumableBytes, 300)
        download.requestDiscard()
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch {}
        assertNoPartial(download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDiscardPartialRemovesAnInterruptedDownload() throws {
        try seedPartial(content.prefix(100), etag: "\"abc\"")
        let download = makeDownload(FakeTransport([]))
        XCTAssertEqual(download.resumableBytes, 100)
        download.discardPartial()
        assertNoPartial(download)
    }

    func testPartialFromAnotherSourceIsNotResumed() async throws {
        try seedPartial(Data(repeating: 0xAA, count: 600), etag: "\"abc\"", url: "https://example.invalid/other.gguf")
        let transport = FakeTransport([.init(status: 200, headers: ["Content-Length": "1000"], body: content)])
        let download = makeDownload(transport)
        XCTAssertEqual(download.resumableBytes, 0)
        try await download.install(verify: verifier(content), progress: { _ in })
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: destination), content)
    }

    func testGivesUpAfterTheRetriesButKeepsThePartialFile() async throws {
        let drop = FakeTransport.Step(status: 206, headers: ["Content-Range": "bytes 100-999/1000"], body: Data(), then: .fail(URLError(.timedOut)))
        try seedPartial(content.prefix(100), etag: nil)
        let pauses = Recorder<TimeInterval>()
        let download = makeDownload(FakeTransport([drop, drop, drop]), pauses: pauses)
        do {
            try await download.install(verify: verifier(content), progress: { _ in })
            XCTFail("expected the network error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(pauses.values, [1, 2])
        XCTAssertEqual(download.resumableBytes, 100)
    }

    func testDoesNotRetryOrResumeAfterAServerError() async throws {
        let pauses = Recorder<TimeInterval>()
        let download = makeDownload(FakeTransport([.init(status: 404, headers: [:], body: Data())]), pauses: pauses)
        do {
            try await download.install(verify: verifier(content), progress: { _ in })
            XCTFail("expected a server error")
        } catch let error as ResumableModelDownloadError {
            XCTAssertEqual(error, .badResponse(404))
        }
        XCTAssertEqual(pauses.values, [])
    }

    private func seedPartial(_ bytes: Data, etag: String?, lastModified: String? = nil, url: String? = nil) throws {
        let partial = destination.deletingLastPathComponent().appendingPathComponent("model.gguf.partial")
        try bytes.write(to: partial)
        var record: [String: Any] = ["url": url ?? source.absoluteString, "byteCount": content.count]
        if let etag { record["etag"] = etag }
        if let lastModified { record["lastModified"] = lastModified }
        try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: partial.path + ".json"))
    }
}

private struct VerifyError: Error {}

final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
}

/// Serves scripted responses in order, in small chunks, and records each request.
private final class FakeTransport: ModelDownloadTransport, @unchecked Sendable {
    enum Ending { case finish, fail(Error), block(AsyncStream<Void>.Continuation) }
    struct Step {
        let status: Int
        let headers: [String: String]
        let body: Data
        var then: Ending = .finish
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var sent: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }

    init(_ steps: [Step]) { self.steps = steps }

    private func next(_ request: URLRequest) -> Step? {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func send(_ request: URLRequest, response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
              data: @escaping @Sendable (Data) throws -> Void) async throws {
        guard let step = next(request) else { throw URLError(.cannotConnectToHost) }
        try response(HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: step.headers)!)
        var offset = step.body.startIndex
        while offset < step.body.endIndex {
            let end = min(offset + 64, step.body.endIndex)
            try data(step.body[offset..<end])
            offset = end
        }
        switch step.then {
        case .finish: return
        case .fail(let error): throw error
        case .block(let signal):
            signal.yield()
            // Wait for cancellation, as a stalled connection would.
            // An AsyncStream's iteration ends when the task is cancelled.
            let (stall, open) = AsyncStream<Void>.makeStream()
            for await _ in stall {}
            open.finish()
            throw URLError(.cancelled)
        }
    }
}
