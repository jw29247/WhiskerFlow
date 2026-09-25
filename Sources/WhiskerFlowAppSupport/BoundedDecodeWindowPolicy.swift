import Foundation

public enum BoundedDecodeWindowPolicy {
    public static let windowSeconds = 30.0
    public static let overlapSeconds = 1.0

    public static func frameRanges(totalFrames: Int64, sampleRate: Double) -> [Range<Int64>] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let window = max(1, Int64(sampleRate * windowSeconds))
        let overlap = min(window - 1, max(0, Int64(sampleRate * overlapSeconds)))
        var ranges: [Range<Int64>] = []
        var start: Int64 = 0
        while start < totalFrames {
            // The last window is anchored to the end of the audio so it is always
            // full length: a stepped tail can be a second of already-owned overlap
            // plus a key click, which Whisper decodes as empty and fails the file.
            if start > 0, totalFrames - start < window { start = totalFrames - window }
            let end = min(totalFrames, start + window)
            ranges.append(start..<end)
            guard end < totalFrames else { break }
            start = end - overlap
        }
        return ranges
    }

    /// The span (seconds) each window owns when stitching timed segments: the
    /// boundary between neighbours sits mid-way through their overlap, which is
    /// wider than `overlapSeconds` for the end-anchored final window.
    public static func ownership(of ranges: [Range<Int64>], sampleRate: Double) -> [Range<Double>] {
        guard sampleRate > 0 else { return [] }
        return ranges.indices.map { index in
            let lower = index == ranges.startIndex
                ? -Double.infinity
                : Double(ranges[index].lowerBound + ranges[index - 1].upperBound) / 2 / sampleRate
            let upper = index == ranges.index(before: ranges.endIndex)
                ? Double.infinity
                : Double(ranges[index + 1].lowerBound + ranges[index].upperBound) / 2 / sampleRate
            return lower..<upper
        }
    }

    public static func containsAudibleActivity(
        _ samples: [Float], sampleRate: Int = 16_000, rmsThreshold: Double = 0.015
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        for start in stride(from: 0, to: samples.count, by: sampleRate) {
            let block = samples[start..<min(samples.count, start + sampleRate)]
            guard !block.isEmpty else { continue }
            let meanSquare = block.reduce(0.0) { $0 + Double($1 * $1) } / Double(block.count)
            if meanSquare.squareRoot() >= rmsThreshold { return true }
        }
        return false
    }
}
