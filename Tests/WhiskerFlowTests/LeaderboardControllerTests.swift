import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Answers Atlas requests in-process and records what was sent.
final class LeaderboardStubProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [[String: Any]] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply: [String: Any] = ["ok": true, "value": ["accepted": 1]]

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
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { Self.requests.append(json) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: Self.reply)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class LeaderboardControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let today = LocalDay(year: 2026, month: 10, day: 2)

    override func setUp() async throws {
        suite = "leaderboard-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        LeaderboardStubProtocol.requests = []
        LeaderboardStubProtocol.status = 200
        LeaderboardStubProtocol.reply = ["ok": true, "value": ["accepted": 1]]
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func controller(days: [LeaderboardDay], signedIn: Bool = true) -> LeaderboardController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LeaderboardStubProtocol.self]
        let session = URLSession(configuration: configuration)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        return LeaderboardController(
            client: { signedIn ? LeaderboardAtlasClient(baseURL: URL(string: "https://atlas.example")!, token: "twnt_test", session: session) : nil },
            usageDays: { _ in days }, defaults: defaults, calendar: { calendar }, now: { noon })
    }

    private func day(_ offset: Int) -> LeaderboardDay {
        LeaderboardDay(day: today.adding(days: -offset), words: 10, dictations: 1, speakingSeconds: 4,
                       timeSavedSeconds: 11, meetings: 0, meetingSeconds: 0)
    }

    private var sentDays: [[String]] {
        LeaderboardStubProtocol.requests.filter { $0["tool"] as? String == "notetaker.leaderboard.report" }.map {
            (($0["args"] as? [String: Any])?["days"] as? [[String: Any]] ?? []).compactMap { $0["day"] as? String }
        }
    }

    func testFirstReportSendsAllHistoryInBatchesThenOnlyRecentDays() async {
        let board = controller(days: (0..<450).reversed().map(day))
        let first = await board.report()
        XCTAssertTrue(first)
        XCTAssertEqual(sentDays.map(\.count), [400, 50])
        LeaderboardStubProtocol.requests = []
        await board.report()
        XCTAssertEqual(sentDays, [["2026-10-01", "2026-10-02"]])
    }

    func testAFailedReportIsRetriedInFullNextTime() async {
        let board = controller(days: (0..<5).reversed().map(day))
        LeaderboardStubProtocol.status = 503
        LeaderboardStubProtocol.reply = ["ok": false, "error": "leaderboard_unavailable"]
        let failed = await board.report()
        XCTAssertFalse(failed)
        LeaderboardStubProtocol.status = 200
        LeaderboardStubProtocol.reply = ["ok": true, "value": ["accepted": 5]]
        LeaderboardStubProtocol.requests = []
        await board.report()
        XCTAssertEqual(sentDays.first?.count, 5)
    }

    func testRefreshLoadsTheWindowAndExplainsAMissingPermission() async {
        let board = controller(days: [])
        LeaderboardStubProtocol.reply = ["ok": true, "value": ["generatedAt": 1, "entries": [[
            "employeeId": "k1", "name": "Ada", "isYou": true, "words": 5, "dictations": 1, "speakingSeconds": 2,
            "timeSavedSeconds": 5, "meetings": 0, "meetingSeconds": 0, "currentStreakDays": 1, "longestStreakDays": 1,
        ]]]]
        board.window = .month
        await board.refresh()
        let get = LeaderboardStubProtocol.requests.last { $0["tool"] as? String == "notetaker.leaderboard.get" }
        XCTAssertEqual((get?["args"] as? [String: Any])?["since"] as? String, "2026-10-01")
        XCTAssertEqual(board.rows.map(\.entry.name), ["Ada"])

        LeaderboardStubProtocol.status = 403
        LeaderboardStubProtocol.reply = ["ok": false, "error": "leaderboard_not_permitted"]
        await board.refresh()
        XCTAssertEqual(board.errorMessage, LeaderboardClientError.notPermitted.errorDescription)
        XCTAssertEqual(board.rows.count, 1, "the last board stays on screen")
    }

    func testSignedOutReportsNothing() async {
        let board = controller(days: [day(0)], signedIn: false)
        let reported = await board.report()
        XCTAssertFalse(reported)
        XCTAssertTrue(LeaderboardStubProtocol.requests.isEmpty)
    }

    func testMeetingsAreTalliedOnceAndSeededOnce() {
        let board = controller(days: [])
        let start = Date(timeIntervalSince1970: 1_790_942_400)
        board.seedMeetingsIfNeeded([(start, 1_800_000), (start, 30_000)])
        board.seedMeetingsIfNeeded([(start, 1_800_000)])
        XCTAssertEqual(board.meetingTally.days.values.map(\.meetings), [1], "short recordings and a second seed don't count")
        board.recordMeeting(startedAt: start, durationMs: 600_000)
        XCTAssertEqual(board.meetingTally.days.values.first?.seconds, 2_400)
    }
}
