import Foundation

/// Bounds the audio a live partial decode has to chew through. The live loop
/// only decodes the samples after the last confirmed cut, so a long hold costs
/// a flat amount of work per pass instead of re-decoding everything each time.
public enum LiveDecodeWindowPolicy {
    public static let sampleRate = 16_000
    /// Below this the window is short enough that re-decoding it is cheap, and
    /// leaving it whole keeps Whisper's context intact.
    public static let freezeAfterSeconds = 8.0
    /// Whisper only attends to a 30 s context; cut well short of it so audio
    /// arriving while a decode is in flight still fits.
    public static let hardCapSeconds = 15.0
    public static let silenceFrameSeconds = 0.1
    public static let minTrailingSilenceSeconds = 0.3
    /// About -40 dBFS. Deliberately low: taking speech for silence would cut a
    /// word in half, while missing a pause only defers the cut to the hard cap.
    public static let silenceRMS: Float = 0.01

    public static let frameSampleCount = Int(Double(sampleRate) * silenceFrameSeconds)
    private static let minSilenceFrames = Int((minTrailingSilenceSeconds / silenceFrameSeconds).rounded())
    private static let freezeSampleCount = Int(Double(sampleRate) * freezeAfterSeconds)
    private static let hardCapSampleCount = Int(Double(sampleRate) * hardCapSeconds)

    /// One RMS value per whole frame; a trailing partial frame is dropped.
    public static func frameRMS(_ samples: [Float]) -> [Float] {
        let frameCount = samples.count / frameSampleCount
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { frame in
            let start = frame * frameSampleCount
            var sum: Float = 0
            for index in start..<(start + frameSampleCount) {
                sum += samples[index] * samples[index]
            }
            return (sum / Float(frameSampleCount)).squareRoot()
        }
    }

    /// The sample index where the window can be split into a confirmed prefix
    /// and a fresh window, or nil to keep growing. Cuts land in the middle of a
    /// quiet run so no word straddles the boundary.
    public static func cutPoint(windowSampleCount: Int, frameRMS: [Float]) -> Int? {
        guard windowSampleCount >= freezeSampleCount, !frameRMS.isEmpty else { return nil }

        var end = frameRMS.count
        while end > 0 {
            guard frameRMS[end - 1] < silenceRMS else {
                end -= 1
                continue
            }
            var start = end - 1
            while start > 0, frameRMS[start - 1] < silenceRMS { start -= 1 }
            if end - start >= minSilenceFrames {
                return clamped(midpoint(start..<end), windowSampleCount)
            }
            end = start
        }

        guard windowSampleCount >= hardCapSampleCount,
              let quietest = frameRMS.indices.min(by: { frameRMS[$0] < frameRMS[$1] })
        else { return nil }
        return clamped(midpoint(quietest..<(quietest + 1)), windowSampleCount)
    }

    /// Stitch the confirmed prefix to the current window's text with a single
    /// space, so the seam never doubles up whitespace or leaves parts fused.
    public static func join(_ confirmed: String, _ window: String) -> String {
        let head = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = window.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }

    private static func midpoint(_ frames: Range<Int>) -> Int {
        (frames.lowerBound + frames.upperBound) * frameSampleCount / 2
    }

    private static func clamped(_ index: Int, _ windowSampleCount: Int) -> Int? {
        let bounded = min(index, windowSampleCount)
        return bounded > 0 ? bounded : nil
    }
}
