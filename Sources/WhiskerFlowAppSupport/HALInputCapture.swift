import Foundation
import os

/// Format and buffer sizes for capturing one input device through an
/// input-only HAL unit. The unit hands over float, deinterleaved audio at the
/// device's own rate and channel count; mixing to mono and conversion to
/// 16 kHz happen afterwards, in ~100 ms chunks, as the engine tap's did.
public struct HALInputCapturePlan: Equatable, Sendable {
    /// Larger than any I/O buffer CoreAudio uses by default; a device can be
    /// asked for more by another app, so the device's own limit raises it.
    public static let minimumRenderFrames = 4_096
    public static let maximumRenderFrames = 65_536
    /// What the pipeline receives per buffer: the tap delivered about ten a
    /// second, which the level meter and the stall watchdog are tuned for.
    public static let chunkSeconds = 0.1
    /// How far the pipeline may fall behind the microphone before audio drops.
    public static let ringSeconds = 2.0
    /// Bounds the ring on interfaces with dozens of channels (16 MB of floats).
    public static let maximumRingSamples = 4_194_304

    public let sampleRate: Double
    public let channelCount: Int
    /// Frames each input callback can render.
    public let renderCapacityFrames: Int
    public let chunkFrames: Int
    public let ringCapacityFrames: Int

    /// `maximumFramesPerSlice` is the unit's, `deviceBufferFrameSizeLimit` the
    /// top of the device's buffer frame size range; either may be unknown.
    public init(
        sampleRate: Double,
        channelCount: Int,
        maximumFramesPerSlice: Int? = nil,
        deviceBufferFrameSizeLimit: Int? = nil
    ) throws {
        try AudioFormatValidator.validate(sampleRate: sampleRate, channelCount: UInt32(clamping: max(0, channelCount)))
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        renderCapacityFrames = min(
            Self.maximumRenderFrames,
            max(Self.minimumRenderFrames, maximumFramesPerSlice ?? 0, deviceBufferFrameSizeLimit ?? 0)
        )
        chunkFrames = max(1, Int((sampleRate * Self.chunkSeconds).rounded()))
        let wanted = Int((sampleRate * Self.ringSeconds).rounded(.up))
        let bounded = min(wanted, Self.maximumRingSamples / channelCount)
        // Always room for a chunk plus two callbacks, however many channels.
        ringCapacityFrames = max(bounded, chunkFrames + 2 * renderCapacityFrames)
    }

    /// Several channels are mixed to mono before conversion; see `mixDown`.
    public var needsMixDown: Bool { channelCount > 1 }

    /// Whether mono audio at this rate still needs converting to `targetRate`.
    public func needsResampling(to targetRate: Double) -> Bool {
        abs(sampleRate - targetRate) > 0.5
    }
}

/// A fixed-size planar float FIFO from the HAL input callback (the writer, on
/// CoreAudio's real-time I/O thread) to the capture's processing queue (the
/// reader). Storage is allocated once, writes never allocate, and the lock is
/// held only for a copy, so the I/O thread does no file or main-actor work.
public final class PlanarAudioRingBuffer: @unchecked Sendable {
    public struct Trouble: Equatable, Sendable {
        /// Frames dropped because the reader fell behind.
        public var droppedFrames = 0
        /// Callbacks whose render failed, and the last status seen.
        public var renderFailures = 0
        public var lastRenderStatus: Int32 = 0

        public init(droppedFrames: Int = 0, renderFailures: Int = 0, lastRenderStatus: Int32 = 0) {
            self.droppedFrames = droppedFrames
            self.renderFailures = renderFailures
            self.lastRenderStatus = lastRenderStatus
        }

        public var isEmpty: Bool { droppedFrames == 0 && renderFailures == 0 }
    }

    public let channelCount: Int
    public let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Absolute frame positions; the difference is what is buffered.
    private var readPosition = 0
    private var writePosition = 0
    private var closed = false
    private var trouble = Trouble()

    public init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0 && capacityFrames > 0)
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    /// Appends `frames` frames, reading channel `c` from `source(c)`. Frames
    /// that do not fit are dropped and counted. Returns false when closed.
    @discardableResult
    public func write(frames: Int, from source: (Int) -> UnsafePointer<Float>) -> Bool {
        guard frames > 0 else { return true }
        return withLock {
            guard !closed else { return false }
            let free = capacityFrames - (writePosition - readPosition)
            guard frames <= free else {
                trouble.droppedFrames += frames
                return true
            }
            let start = writePosition % capacityFrames
            let first = min(frames, capacityFrames - start)
            for channel in 0..<channelCount {
                let from = source(channel)
                let base = storage + channel * capacityFrames
                (base + start).update(from: from, count: first)
                if first < frames { base.update(from: from + first, count: frames - first) }
            }
            writePosition += frames
            return true
        }
    }

    /// Moves up to `maxFrames` of the oldest frames into `destination`, one
    /// pointer per channel, and returns how many it moved.
    public func read(into destination: UnsafePointer<UnsafeMutablePointer<Float>>, maxFrames: Int) -> Int {
        withLock {
            let frames = min(maxFrames, writePosition - readPosition)
            guard frames > 0 else { return 0 }
            let start = readPosition % capacityFrames
            let first = min(frames, capacityFrames - start)
            for channel in 0..<channelCount {
                let base = storage + channel * capacityFrames
                destination[channel].update(from: base + start, count: first)
                if first < frames { (destination[channel] + first).update(from: base, count: frames - first) }
            }
            readPosition += frames
            return frames
        }
    }

    public var availableFrames: Int { withLock { writePosition - readPosition } }

    public func recordRenderFailure(_ status: Int32) {
        withLock {
            trouble.renderFailures += 1
            trouble.lastRenderStatus = status
        }
    }

    /// Drops and render failures since the last call.
    public func takeTrouble() -> Trouble {
        withLock {
            defer { trouble = Trouble() }
            return trouble
        }
    }

    /// Rejects further writes; what is buffered can still be read.
    public func close() { withLock { closed = true } }

    /// Empties the buffer and accepts writes again, for the next capture.
    public func reopen() {
        withLock {
            readPosition = 0
            writePosition = 0
            trouble = Trouble()
            closed = false
        }
    }
}

/// What a capture device looked like when read; `nil` where CoreAudio could
/// not say.
public struct CaptureDeviceState: Equatable, Sendable {
    public var isAlive: Bool
    public var nominalSampleRate: Double?
    public var inputChannelCount: Int?
    public var defaultInputDeviceID: UInt32?

    public init(isAlive: Bool, nominalSampleRate: Double?, inputChannelCount: Int?, defaultInputDeviceID: UInt32?) {
        self.isAlive = isAlive
        self.nominalSampleRate = nominalSampleRate
        self.inputChannelCount = inputChannelCount
        self.defaultInputDeviceID = defaultInputDeviceID
    }
}

/// A change that leaves a capture recording the wrong thing, or nothing.
public enum CaptureDeviceChange: String, Equatable, Sendable {
    case deviceLost = "device_lost"
    case sampleRateChanged = "sample_rate_changed"
    case channelsChanged = "channels_changed"
    /// A system-default capture whose default input moved to another device.
    case defaultInputChanged = "default_input_changed"
}

/// The device a capture unit was built for, as it was then. CoreAudio
/// property listeners fire for many reasons, including the capture's own
/// start, so only a value that differs from build time counts as a change.
public struct CaptureDeviceExpectation: Equatable, Sendable {
    public let deviceID: UInt32
    public let nominalSampleRate: Double?
    public let inputChannelCount: Int?
    public let followsSystemDefault: Bool

    public init(deviceID: UInt32, builtWith state: CaptureDeviceState, followsSystemDefault: Bool) {
        self.deviceID = deviceID
        nominalSampleRate = state.nominalSampleRate
        inputChannelCount = state.inputChannelCount
        self.followsSystemDefault = followsSystemDefault
    }

    /// Unknown values never count as a change: a read that fails while
    /// CoreAudio churns must not end a capture that is still recording.
    public func change(in state: CaptureDeviceState) -> CaptureDeviceChange? {
        guard state.isAlive, state.inputChannelCount != 0 else { return .deviceLost }
        if followsSystemDefault, let current = state.defaultInputDeviceID, current != deviceID {
            return .defaultInputChanged
        }
        if let expected = nominalSampleRate, let current = state.nominalSampleRate, abs(expected - current) > 0.5 {
            return .sampleRateChanged
        }
        if let expected = inputChannelCount, let current = state.inputChannelCount, expected != current {
            return .channelsChanged
        }
        return nil
    }
}
