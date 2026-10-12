import XCTest
@testable import WhiskerFlowAppSupport

final class HALInputCapturePlanTests: XCTestCase {
    func testCommonDeviceRatesGetTenthOfASecondChunks() throws {
        for (rate, chunk) in [(48_000.0, 4_800), (44_100.0, 4_410), (16_000.0, 1_600), (96_000.0, 9_600)] {
            let plan = try HALInputCapturePlan(sampleRate: rate, channelCount: 1)
            XCTAssertEqual(plan.chunkFrames, chunk, "\(rate) Hz")
            XCTAssertEqual(plan.renderCapacityFrames, HALInputCapturePlan.minimumRenderFrames)
            XCTAssertGreaterThanOrEqual(plan.ringCapacityFrames, Int(rate * HALInputCapturePlan.ringSeconds))
        }
    }

    func testOnlySixteenKilohertzMonoSkipsConversion() throws {
        XCTAssertFalse(try HALInputCapturePlan(sampleRate: 16_000, channelCount: 1).needsResampling(to: 16_000))
        XCTAssertFalse(try HALInputCapturePlan(sampleRate: 16_000, channelCount: 1).needsMixDown)
        XCTAssertTrue(try HALInputCapturePlan(sampleRate: 16_000, channelCount: 2).needsMixDown)
        XCTAssertTrue(try HALInputCapturePlan(sampleRate: 44_100, channelCount: 1).needsResampling(to: 16_000))
    }

    func testRenderCapacityCoversTheDeviceBufferLimit() throws {
        let plan = try HALInputCapturePlan(
            sampleRate: 48_000, channelCount: 2, maximumFramesPerSlice: 512, deviceBufferFrameSizeLimit: 8_192)
        XCTAssertEqual(plan.renderCapacityFrames, 8_192)
        let absurd = try HALInputCapturePlan(
            sampleRate: 48_000, channelCount: 2, maximumFramesPerSlice: nil, deviceBufferFrameSizeLimit: 10_000_000)
        XCTAssertEqual(absurd.renderCapacityFrames, HALInputCapturePlan.maximumRenderFrames)
    }

    /// A 64-channel interface at 192 kHz must not allocate hundreds of MB,
    /// but still holds a chunk plus two callbacks.
    func testManyChannelRingIsBoundedButUsable() throws {
        let plan = try HALInputCapturePlan(sampleRate: 192_000, channelCount: 64)
        XCTAssertLessThanOrEqual(plan.ringCapacityFrames * 64, HALInputCapturePlan.maximumRingSamples)
        XCTAssertGreaterThanOrEqual(plan.ringCapacityFrames, plan.chunkFrames + 2 * plan.renderCapacityFrames)
    }

    func testInvalidDeviceFormatsAreRejected() {
        XCTAssertThrowsError(try HALInputCapturePlan(sampleRate: 0, channelCount: 1))
        XCTAssertThrowsError(try HALInputCapturePlan(sampleRate: .nan, channelCount: 1))
        XCTAssertThrowsError(try HALInputCapturePlan(sampleRate: 48_000, channelCount: 0))
        XCTAssertThrowsError(try HALInputCapturePlan(sampleRate: 48_000, channelCount: -2))
    }
}

final class PlanarAudioRingBufferTests: XCTestCase {
    private func write(_ ring: PlanarAudioRingBuffer, _ channels: [[Float]]) -> Bool {
        let frames = channels[0].count
        let copies = channels.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            pointer.initialize(from: channel, count: frames)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        return ring.write(frames: frames) { UnsafePointer(copies[$0]) }
    }

    private func read(_ ring: PlanarAudioRingBuffer, maxFrames: Int) -> [[Float]] {
        let destinations = (0..<ring.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: maxFrames) }
        defer { destinations.forEach { $0.deallocate() } }
        let frames = destinations.withUnsafeBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: maxFrames) }
        return destinations.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    func testFramesComeOutInOrderPerChannelAcrossTheWrap() {
        let ring = PlanarAudioRingBuffer(channelCount: 2, capacityFrames: 5)
        XCTAssertTrue(write(ring, [[1, 2, 3], [-1, -2, -3]]))
        XCTAssertEqual(read(ring, maxFrames: 2), [[1, 2], [-1, -2]])
        XCTAssertTrue(write(ring, [[4, 5, 6, 7], [-4, -5, -6, -7]]))
        XCTAssertEqual(ring.availableFrames, 5)
        XCTAssertEqual(read(ring, maxFrames: 10), [[3, 4, 5, 6, 7], [-3, -4, -5, -6, -7]])
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testAWriteThatDoesNotFitIsDroppedAndCounted() {
        let ring = PlanarAudioRingBuffer(channelCount: 1, capacityFrames: 4)
        XCTAssertTrue(write(ring, [[1, 2, 3]]))
        XCTAssertTrue(write(ring, [[4, 5]]))
        XCTAssertEqual(ring.takeTrouble(), .init(droppedFrames: 2))
        XCTAssertEqual(ring.takeTrouble(), .init(), "Reported once")
        XCTAssertEqual(read(ring, maxFrames: 4), [[1, 2, 3]], "Older audio is kept")
    }

    func testRenderFailuresAreCountedWithTheLastStatus() {
        let ring = PlanarAudioRingBuffer(channelCount: 1, capacityFrames: 4)
        ring.recordRenderFailure(-10863)
        ring.recordRenderFailure(-10874)
        XCTAssertEqual(ring.takeTrouble(), .init(renderFailures: 2, lastRenderStatus: -10874))
    }

    /// Stopping closes the ring so the callback adds nothing while the rest
    /// is drained; the next capture starts empty.
    func testCloseKeepsWhatIsBufferedAndReopenEmpties() {
        let ring = PlanarAudioRingBuffer(channelCount: 1, capacityFrames: 8)
        XCTAssertTrue(write(ring, [[1, 2]]))
        ring.close()
        XCTAssertFalse(write(ring, [[3]]))
        XCTAssertEqual(read(ring, maxFrames: 8), [[1, 2]])
        XCTAssertTrue(write(ring, [[9]]) == false)
        ring.reopen()
        XCTAssertEqual(ring.availableFrames, 0)
        XCTAssertTrue(write(ring, [[4]]))
        XCTAssertEqual(read(ring, maxFrames: 8), [[4]])
    }

    func testConcurrentWriterAndReaderLoseNothing() {
        let ring = PlanarAudioRingBuffer(channelCount: 1, capacityFrames: 1_024)
        let total = 50_000
        let writer = Thread {
            var next: Float = 0
            var buffer = [Float](repeating: 0, count: 100)
            while next < Float(total) {
                guard ring.availableFrames <= 1_024 - 100 else { continue }
                for index in buffer.indices { buffer[index] = next + Float(index) }
                buffer.withUnsafeBufferPointer { pointer in _ = ring.write(frames: 100) { _ in pointer.baseAddress! } }
                next += 100
            }
        }
        writer.start()
        var received: [Float] = []
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { destination.deallocate() }
        var channels = [destination]
        let deadline = Date().addingTimeInterval(10)
        while received.count < total, Date() < deadline {
            let frames = channels.withUnsafeMutableBufferPointer { ring.read(into: UnsafePointer($0.baseAddress!), maxFrames: 256) }
            received.append(contentsOf: UnsafeBufferPointer(start: destination, count: frames))
        }
        XCTAssertEqual(received.count, total)
        XCTAssertEqual(received, (0..<total).map(Float.init))
        XCTAssertEqual(ring.takeTrouble(), .init())
    }
}

final class CaptureDeviceExpectationTests: XCTestCase {
    private let built = CaptureDeviceState(isAlive: true, nominalSampleRate: 48_000, inputChannelCount: 2, defaultInputDeviceID: 86)

    private func expectation(followsSystemDefault: Bool = false) -> CaptureDeviceExpectation {
        CaptureDeviceExpectation(deviceID: 86, builtWith: built, followsSystemDefault: followsSystemDefault)
    }

    /// Listeners also fire for the capture's own start; unchanged values are
    /// not a change.
    func testUnchangedValuesAreNotAChange() {
        XCTAssertNil(expectation().change(in: built))
        XCTAssertNil(expectation(followsSystemDefault: true).change(in: built))
    }

    func testDeviceThatDiesOrLosesItsInputIsLost() {
        var state = built
        state.isAlive = false
        XCTAssertEqual(expectation().change(in: state), .deviceLost)
        state = built
        state.inputChannelCount = 0
        XCTAssertEqual(expectation().change(in: state), .deviceLost)
    }

    func testSampleRateAndChannelChangesAreReported() {
        var state = built
        state.nominalSampleRate = 44_100
        XCTAssertEqual(expectation().change(in: state), .sampleRateChanged)
        state = built
        state.nominalSampleRate = 48_000.0001
        XCTAssertNil(expectation().change(in: state), "Float noise is not a rate change")
        state = built
        state.inputChannelCount = 4
        XCTAssertEqual(expectation().change(in: state), .channelsChanged)
    }

    /// 2 October: a system-default capture must not keep recording the C920
    /// after the default input moves to a headset, nor the other way round;
    /// a specific microphone ignores the default entirely.
    func testDefaultInputChangesOnlyMatterForSystemDefaultCaptures() {
        var state = built
        state.defaultInputDeviceID = 163
        XCTAssertEqual(expectation(followsSystemDefault: true).change(in: state), .defaultInputChanged)
        XCTAssertNil(expectation(followsSystemDefault: false).change(in: state))
    }

    func testUnreadableValuesNeverEndACapture() {
        let unknown = CaptureDeviceState(isAlive: true, nominalSampleRate: nil, inputChannelCount: nil, defaultInputDeviceID: nil)
        XCTAssertNil(expectation(followsSystemDefault: true).change(in: unknown))
        let builtBlind = CaptureDeviceExpectation(deviceID: 86, builtWith: unknown, followsSystemDefault: false)
        XCTAssertNil(builtBlind.change(in: built))
    }
}
