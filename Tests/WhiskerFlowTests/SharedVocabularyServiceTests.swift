import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Answers glossary requests in-process, by bearer token, and records what was sent.
final class GlossaryStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: [String: Any]
        var delay: TimeInterval = 0
    }

    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var fallback = Reply(status: 200, body: ["ok": true, "value": ["rules": []]])

    static func reset() {
        requests = []
        bodies = []
        replies = [:]
        fallback = Reply(status: 200, body: ["ok": true, "value": ["rules": []]])
    }

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? request.httpBody ?? Data()
        Self.requests.append(request)
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { Self.bodies.append(json) }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let reply = Self.replies[token] ?? Self.fallback
        let respond = { [self] in
            lock.lock()
            let wasStopped = stopped
            lock.unlock()
            guard !wasStopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

@MainActor
final class SharedVocabularyServiceTests: XCTestCase {
    private static let firstToken = "twnt_first_device_token_0001"
    private static let secondToken = "twnt_second_device_token_0002"

    private var cacheURL: URL!
    private var token: String?

    override func setUp() async throws {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-vocabulary-tests-\(UUID().uuidString).json")
        token = Self.firstToken
        GlossaryStubProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func makeService() -> SharedVocabularyService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GlossaryStubProtocol.self]
        let session = URLSession(configuration: configuration)
        return SharedVocabularyService(client: { [unowned self] in
            self.token.map { GlossaryAtlasClient(baseURL: URL(string: "https://atlas.example")!, token: $0, session: session) }
        }, cacheURL: cacheURL)
    }

    private func glossary(_ pairs: [(String, String)]) -> [String: Any] {
        ["rules": pairs.map { ["find": $0.0, "replaceWith": $0.1] }]
    }

    private func writeCache(_ pairs: [(String, String)]) throws {
        try JSONSerialization.data(withJSONObject: glossary(pairs)).write(to: cacheURL)
    }

    private func cachedFinds() throws -> [String] {
        try JSONDecoder().decode(Vocabulary.self, from: Data(contentsOf: cacheURL)).rules.map(\.find)
    }

    func testRequestUsesTheNotetakerToolWithTheDeviceTokenAndNoUserData() async throws {
        let service = makeService()
        service.start()
        await service.waitForCurrentFetch()

        XCTAssertEqual(GlossaryStubProtocol.requests.count, 1)
        let request = try XCTUnwrap(GlossaryStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://atlas.example/api/notetaker")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.firstToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(Int(request.value(forHTTPHeaderField: "x-request-timestamp") ?? ""))
        let body = try XCTUnwrap(GlossaryStubProtocol.bodies.first)
        XCTAssertEqual(Set(body.keys), ["tool", "args"])
        XCTAssertEqual(body["tool"] as? String, "notetaker.glossary.get")
        XCTAssertEqual((body["args"] as? [String: Any])?.isEmpty, true)
    }

    func testANewInstallWithNoCacheHasAnEmptyGlossaryAndNoError() async {
        token = nil
        let service = makeService()
        XCTAssertTrue(service.rules.isEmpty, "the app ships no glossary of its own")
        XCTAssertEqual(service.status, .idle)

        service.start()
        await service.waitForCurrentFetch()
        XCTAssertTrue(GlossaryStubProtocol.requests.isEmpty)
        XCTAssertTrue(service.rules.isEmpty)
        XCTAssertEqual(service.status, .idle, "signed out with nothing downloaded is not an error")
        XCTAssertTrue(service.vocabulary.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testTheFirstFetchFromAtlasPopulatesAndCachesTheGlossary() async throws {
        GlossaryStubProtocol.fallback = .init(status: 200, body: ["ok": true, "value": glossary([("zorblat", "Zorblat")])])
        let service = makeService()
        XCTAssertTrue(service.rules.isEmpty)

        service.start()
        await service.waitForCurrentFetch()

        XCTAssertEqual(service.rules.map(\.replaceWith), ["Zorblat"])
        guard case .loaded(let count, _) = service.status, count == 1 else { return XCTFail("status \(service.status)") }
        XCTAssertEqual(try cachedFinds(), ["zorblat"])
        XCTAssertEqual(makeService().rules.map(\.find), ["zorblat"], "the next launch starts from the cached copy")
    }

    func testSuccessReplacesTheRulesAndCachesThemIgnoringUnknownFields() async throws {
        try writeCache([("zorblat", "Zorblat")])
        var value = glossary([("quindle", "Quindle")])
        value["revision"] = 7
        value["rules"] = [["find": "quindle", "replaceWith": "Quindle", "owner": "ops"]]
        GlossaryStubProtocol.fallback = .init(status: 200, body: ["ok": true, "value": value])
        let service = makeService()
        XCTAssertEqual(service.rules.map(\.find), ["zorblat"], "the cache loads before any fetch")

        service.start()
        await service.waitForCurrentFetch()

        XCTAssertEqual(service.rules.map(\.replaceWith), ["Quindle"])
        guard case .loaded(let count, _) = service.status, count == 1 else { return XCTFail("status \(service.status)") }
        XCTAssertEqual(try cachedFinds(), ["quindle"])
    }

    func testFailuresKeepTheCachedRules() async throws {
        let failures: [(String, GlossaryStubProtocol.Reply)] = [
            ("tool not deployed", .init(status: 400, body: ["ok": false, "error": "unknown_tool"])),
            ("signed out", .init(status: 401, body: ["ok": false, "error": "unauthorized"])),
            ("forbidden", .init(status: 403, body: ["ok": false, "error": "forbidden"])),
            ("rate limited", .init(status: 429, body: ["ok": false, "error": "rate_limited"])),
            ("server error", .init(status: 503, body: ["ok": false, "error": "unavailable"])),
            ("invalid payload", .init(status: 200, body: ["ok": true, "value": ["rules": "nope"]])),
        ]
        for (name, reply) in failures {
            try writeCache([("zorblat", "Zorblat")])
            GlossaryStubProtocol.fallback = reply
            let service = makeService()
            service.start()
            await service.waitForCurrentFetch()

            XCTAssertEqual(service.rules.map(\.find), ["zorblat"], name)
            XCTAssertEqual(try cachedFinds(), ["zorblat"], "\(name) must not touch the cache")
            guard case .failed = service.status else { return XCTFail("\(name): status \(service.status)") }
        }
    }

    func testErrorMapping() {
        XCTAssertEqual(GlossaryClientError.error(status: 400, code: "unknown_tool"), .notDeployed)
        XCTAssertEqual(GlossaryClientError.error(status: 401, code: nil), .signedOut)
        XCTAssertEqual(GlossaryClientError.error(status: 403, code: nil), .notPermitted)
        XCTAssertEqual(GlossaryClientError.error(status: 429, code: nil), .rateLimited)
        XCTAssertEqual(GlossaryClientError.error(status: 502, code: nil), .unavailable)
    }

    func testSignedOutMakesNoRequestAndKeepsTheCacheWithoutAnError() async throws {
        try writeCache([("zorblat", "Zorblat")])
        token = nil
        let service = makeService()
        service.start()
        service.refresh()
        await service.waitForCurrentFetch()

        XCTAssertTrue(GlossaryStubProtocol.requests.isEmpty)
        XCTAssertEqual(service.rules.map(\.find), ["zorblat"])
        guard case .loaded = service.status else { return XCTFail("status \(service.status)") }
    }

    func testSignInFetchesPromptlyAndSignOutStopsUsingTheToken() async {
        token = nil
        GlossaryStubProtocol.fallback = .init(status: 200, body: ["ok": true, "value": glossary([("zorblat", "Zorblat")])])
        let service = makeService()
        service.start()
        XCTAssertTrue(GlossaryStubProtocol.requests.isEmpty)

        token = Self.firstToken
        service.credentialsChanged()
        await service.waitForCurrentFetch()
        XCTAssertEqual(GlossaryStubProtocol.requests.count, 1)
        XCTAssertEqual(service.rules.map(\.find), ["zorblat"])

        service.credentialsChanged()
        XCTAssertEqual(GlossaryStubProtocol.requests.count, 1, "an unchanged token doesn't refetch")

        token = nil
        service.credentialsChanged()
        service.refresh()
        await service.waitForCurrentFetch()
        XCTAssertEqual(GlossaryStubProtocol.requests.count, 1, "signed out, nothing is requested")
        XCTAssertEqual(service.rules.map(\.find), ["zorblat"], "signing out keeps the last good rules")
    }

    func testASupersededFetchNeverCommits() async throws {
        GlossaryStubProtocol.replies[Self.firstToken] = .init(
            status: 200, body: ["ok": true, "value": glossary([("zorblat", "Zorblat")])], delay: 0.3)
        GlossaryStubProtocol.replies[Self.secondToken] = .init(
            status: 200, body: ["ok": true, "value": glossary([("quindle", "Quindle")])])
        let service = makeService()
        service.start()
        // Let the slow first request reach Atlas before a reconnect supersedes it.
        for _ in 0..<200 where GlossaryStubProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        token = Self.secondToken
        service.credentialsChanged()
        await service.waitForCurrentFetch()
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(GlossaryStubProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer \(Self.firstToken)", "Bearer \(Self.secondToken)"])
        XCTAssertEqual(service.rules.map(\.find), ["quindle"])
        XCTAssertEqual(try cachedFinds(), ["quindle"])
    }

    func testExplicitSignOutDeletesTheDownloadedGlossaryAndStopsRefreshing() async throws {
        GlossaryStubProtocol.replies[Self.firstToken] = .init(status: 200, body: ["ok": true, "value": glossary([("acme", "ACME")])])
        let service = makeService()
        service.start()
        await service.waitForCurrentFetch()
        service.startPeriodicRefresh()
        XCTAssertEqual(try cachedFinds(), ["acme"])

        token = nil
        service.signOut()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), "The client glossary is not kept on this Mac")
        XCTAssertTrue(service.rules.isEmpty, "Signed out, the glossary is empty, as on a new install")
        XCTAssertEqual(service.status, .idle)
        XCTAssertTrue(makeService().rules.isEmpty, "Nothing comes back on the next launch")
        XCTAssertFalse(service.isRefreshingPeriodically)
        let sent = GlossaryStubProtocol.requests.count
        service.refresh()
        service.credentialsChanged()
        XCTAssertEqual(GlossaryStubProtocol.requests.count, sent, "Nothing is requested signed out")

        token = Self.secondToken
        GlossaryStubProtocol.replies[Self.secondToken] = .init(status: 200, body: ["ok": true, "value": glossary([("globex", "Globex")])])
        service.credentialsChanged()
        await service.waitForCurrentFetch()
        XCTAssertEqual(service.rules.map(\.find), ["globex"], "Signing in again fetches the glossary without a restart")
        XCTAssertEqual(GlossaryStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.secondToken)")
    }
}
