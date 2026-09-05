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
            let end = min(totalFrames, start + window)
            ranges.append(start..<end)
            guard end < totalFrames else { break }
            start = end - overlap
        }
        return ranges
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
