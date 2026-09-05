import XCTest
import CryptoKit
import AVFoundation
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class MeetingCoordinatorTests: XCTestCase {
    func testOlderRecoveryCannotOverwriteNewestStoppedMeetingStatus() {
        let olderRecovery = UUID()
        let freshMeeting = UUID()

        XCTAssertFalse(
            MeetingStatusPublicationPolicy.canPublish(
                sessionID: olderRecovery,
                activeSessionID: nil,
                statusOwnerSessionID: freshMeeting
            ),
            "Clearing active capture before delivery must not let stale recovery failures own the UI"
        )
        XCTAssertTrue(
            MeetingStatusPublicationPolicy.canPublish(
                sessionID: freshMeeting,
                activeSessionID: nil,
                statusOwnerSessionID: freshMeeting
            )
        )
    }

    func testRecoveryCanPublishBeforeAnyNewCaptureClaimsStatus() {
        XCTAssertTrue(
            MeetingStatusPublicationPolicy.canPublish(
                sessionID: UUID(),
                activeSessionID: nil,
                statusOwnerSessionID: nil
            )
        )
    }

    func testThreeHourMeetingIsPartitionedIntoBoundedTranscriptionWindows() {
        let descriptors = (0..<1_102).map { sequence in
            MeetingRecordingChunkDescriptor(
                track: .mixed,
                sequence: sequence,
                startMs: Int64(sequence * 10_000),
                endMs: Int64((sequence + 1) * 10_000),
                byteSize: 640_000,
                checksum: "fixture",
                relativePath: "fixture-\(sequence)"
            )
        }

        let windows = MeetingTranscriptionWindowPolicy.windows(descriptors)

        XCTAssertEqual(
            Array(Set(windows.flatMap { $0 }.map(\.sequence))).sorted(),
            descriptors.map(\.sequence)
        )
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { window in
            guard let first = window.first, let last = window.last else { return false }
            return last.endMs - first.startMs <= MeetingTranscriptionWindowPolicy.maximumDurationMs
        })
        XCTAssertEqual(windows[0].last?.sequence, windows[1].first?.sequence)
    }

    func testMeetingDecodeUsesOneWhisperWorker() {
        let options = WhisperKitEngine.decodingOptions(
            language: "en",
            withoutTimestamps: false,
            wordTimestamps: true,
            concurrentWorkerCount: 1
        )
        XCTAssertEqual(options.concurrentWorkerCount, 1)
    }

    func testTranscriptionWindowsSplitAtSourceGaps() {
        let descriptors = [
            chunk(sequence: 0, startMs: 0, endMs: 10_000),
            chunk(sequence: 1, startMs: 10_000, endMs: 20_000),
            chunk(sequence: 3, startMs: 30_000, endMs: 40_000),
        ]

        XCTAssertEqual(
            MeetingTranscriptionWindowPolicy.windows(descriptors).map { $0.map(\.sequence) },
            [[0, 1], [3]]
        )
    }

    func testTimedOutDecodeKeepsGateOccupiedUntilUnderlyingWorkActuallySettles() async throws {
        let gate = ModelDecodeGate()
        let workStarted = expectation(description: "work started")
        let releaseWork = AsyncMeetingTestLatch()
        let timedOut = Task {
            try await gate.run(seconds: 0.01) {
                workStarted.fulfill()
                await releaseWork.wait()
                return "late result"
            }
        }
        await fulfillment(of: [workStarted], timeout: 1)
        do {
            _ = try await timedOut.value
            XCTFail("The caller should be released at its deadline")
        } catch AsyncTimeoutError.timedOut {}

        let occupiedAfterTimeout = await gate.isOccupied
        XCTAssertTrue(occupiedAfterTimeout)
        do {
            _ = try await gate.run(seconds: 1) { "must not start" }
            XCTFail("A retry must not overlap the abandoned Core ML operation")
        } catch ModelDecodeGateError.occupied {}

        await releaseWork.open()
        for _ in 0..<100 {
            if !(await gate.isOccupied) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let occupiedAfterSettlement = await gate.isOccupied
        XCTAssertFalse(occupiedAfterSettlement)
        let next = try await gate.run(seconds: 1) { "next" }
        XCTAssertEqual(next, "next")
    }

    func testModelLoadReservationRejectsConcurrentOperation() async throws {
        let gate = ModelDecodeGate()
        let started = expectation(description: "model load started")
        let release = AsyncMeetingTestLatch()
        let first = Task {
            try await gate.runExclusive {
                started.fulfill()
                await release.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)

        do {
            try await gate.runExclusive { XCTFail("A second model load must not start") }
            XCTFail("Concurrent model preparation must be rejected")
        } catch ModelDecodeGateError.occupied {}

        await release.open()
        try await first.value
        try await gate.runExclusive {}
    }

    func testLocalProcessorDecodesBoundedWindowsAndRebasesSegmentTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingChunkStore(
            rootURL: root.appendingPathComponent("recordings"),
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        try store.beginSession(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.microphone: 7, .mixed: 7]
        )
        for track in [MeetingAudioTrack.microphone, .mixed] {
            for sequence in 0..<7 {
                _ = try store.writeChunk(
                    sessionID: sessionID,
                    track: track,
                    sequence: sequence,
                    startMs: Int64(sequence * 10_000),
                    endMs: Int64((sequence + 1) * 10_000),
                    plaintext: Data(repeating: 0, count: 640_000)
                )
            }
        }
        let observations = MeetingDecodeObservations()
        let processingRoot = root.appendingPathComponent("processing")
        let processor = MeetingLocalProcessor(processingRoot: processingRoot) { url, language in
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            let decodeIndex = await observations.record(seconds)
            let marker = url.lastPathComponent
            // The second window repeats the previous 10-second chunk for
            // acoustic context. Emit after that overlap to verify rebasing.
            let localStart = decodeIndex.isMultiple(of: 2) ? 10.0 : 0
            return TranscriptionResult(
                text: marker,
                segments: [TranscriptionSegment(text: marker, start: localStart, end: seconds)],
                language: language,
                duration: seconds
            )
        }

        let result = try await processor.process(
            manifest: store.loadManifest(sessionID: sessionID),
            store: store,
            language: "en"
        )

        let durations = await observations.durations
        XCTAssertEqual(durations.count, 4, "Two bounded windows are decoded for canonical and microphone tracks")
        XCTAssertTrue(durations.allSatisfy { $0 <= 60.01 })
        XCTAssertTrue(result.turns.contains { abs($0.startMs - 60_000) <= 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingRoot.appendingPathComponent(sessionID.uuidString).path))
    }

    func testCancelledWindowProcessingRemovesTemporaryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingChunkStore(
            rootURL: root.appendingPathComponent("recordings"),
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        try store.beginSession(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.mixed: 7]
        )
        for sequence in 0..<7 {
            _ = try store.writeChunk(
                sessionID: sessionID,
                track: .mixed,
                sequence: sequence,
                startMs: Int64(sequence * 10_000),
                endMs: Int64((sequence + 1) * 10_000),
                plaintext: Data(repeating: 0, count: 640_000)
            )
        }
        let processingRoot = root.appendingPathComponent("processing")
        let calls = MeetingDecodeObservations()
        let processor = MeetingLocalProcessor(processingRoot: processingRoot) { _, _ in
            await calls.record(0)
            if await calls.durations.count == 2 { throw CancellationError() }
            return TranscriptionResult(
                text: "window",
                segments: [TranscriptionSegment(text: "window", start: 0, end: 1)]
            )
        }

        do {
            _ = try await processor.process(
                manifest: store.loadManifest(sessionID: sessionID),
                store: store,
                language: "en"
            )
            XCTFail("Cancellation must stop before another window is materialized")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingRoot.appendingPathComponent(sessionID.uuidString).path))
    }

    func testOverlappingWindowsDeduplicateBoundarySpeechAndSkipSilentWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingChunkStore(
            rootURL: root.appendingPathComponent("recordings"),
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 12])
        for sequence in 0..<12 {
            _ = try store.writeChunk(
                sessionID: sessionID,
                track: .mixed,
                sequence: sequence,
                startMs: Int64(sequence * 10_000),
                endMs: Int64((sequence + 1) * 10_000),
                plaintext: Data(repeating: 0, count: 640_000)
            )
        }
        let calls = MeetingDecodeObservations()
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { _, _ in
            switch await calls.record(0) {
            case 1:
                return TranscriptionResult(
                    text: "boundary",
                    segments: [TranscriptionSegment(text: "boundary", start: 50, end: 60)]
                )
            case 2:
                return TranscriptionResult(
                    text: "boundary next",
                    segments: [
                        TranscriptionSegment(text: "boundary", start: 0, end: 10),
                        TranscriptionSegment(text: "next", start: 10, end: 20),
                    ]
                )
            default:
                throw TranscriptionError.emptyTranscript
            }
        }

        let result = try await processor.process(
            manifest: store.loadManifest(sessionID: sessionID),
            store: store,
            language: "en"
        )

        XCTAssertEqual(result.turns.map(\.text), ["boundary", "next"])
        XCTAssertEqual(result.turns.map(\.startMs), [50_000, 60_000])
    }

    private func chunk(sequence: Int, startMs: Int64, endMs: Int64) -> MeetingRecordingChunkDescriptor {
        MeetingRecordingChunkDescriptor(
            track: .mixed,
            sequence: sequence,
            startMs: startMs,
            endMs: endMs,
            byteSize: 1,
            checksum: "fixture",
            relativePath: "fixture"
        )
    }

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

private actor AsyncMeetingTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MeetingDecodeObservations {
    private(set) var durations: [Double] = []
    @discardableResult
    func record(_ duration: Double) -> Int {
        durations.append(duration)
        return durations.count
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
