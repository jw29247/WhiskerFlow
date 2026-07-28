import Foundation

public enum AudioSignalQuality: Equatable, Sendable {
    case unknown
    case ok
    case tooQuiet
    case clipping

    public var isWarning: Bool {
        self == .tooQuiet || self == .clipping
    }
}

/// Rolling verdict on whether the microphone is actually delivering usable audio.
///
/// Levels arrive already normalized to 0...1 by the capture tap (dB clamped to
/// -50...0, then mapped), so `quietLevelThreshold` of 0.10 is about -45 dBFS.
public struct AudioSignalAssessor: Sendable {
    /// No verdict before this much audio: mics ramp up and the first buffers of
    /// a hold are routinely silent while the speaker is still starting.
    public static let graceSeconds: TimeInterval = 1.5
    public static let windowSeconds: TimeInterval = 2
    public static let quietLevelThreshold: Float = 0.10
    public static let clippingPeakThreshold: Float = 0.99
    /// A single clipped buffer is a transient; a sustained share of them is a
    /// gain problem worth telling the user about.
    public static let clippingBufferFraction = 0.15

    private struct Reading {
        let level: Float
        let peak: Float
        let time: TimeInterval
    }

    private let now: @Sendable () -> TimeInterval
    private var readings: [Reading] = []
    private var startedAt: TimeInterval?

    public private(set) var quality: AudioSignalQuality = .unknown

    public init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
    }

    public mutating func reset() {
        readings.removeAll(keepingCapacity: true)
        startedAt = nil
        quality = .unknown
    }

    @discardableResult
    public mutating func ingest(level: Float, peak: Float) -> AudioSignalQuality {
        ingest(level: level, peak: peak, at: now())
    }

    @discardableResult
    public mutating func ingest(level: Float, peak: Float, at time: TimeInterval) -> AudioSignalQuality {
        let start = startedAt ?? time
        startedAt = start
        readings.append(Reading(level: level, peak: peak, time: time))
        readings.removeAll { $0.time < time - Self.windowSeconds }
        quality = verdict(elapsed: time - start)
        return quality
    }

    private func verdict(elapsed: TimeInterval) -> AudioSignalQuality {
        guard elapsed >= Self.graceSeconds, !readings.isEmpty else { return .unknown }
        let clipped = readings.filter { $0.peak >= Self.clippingPeakThreshold }.count
        if clipped > 0, Double(clipped) >= Double(readings.count) * Self.clippingBufferFraction {
            return .clipping
        }
        let loudest = readings.map(\.level).max() ?? 0
        return loudest < Self.quietLevelThreshold ? .tooQuiet : .ok
    }
}
