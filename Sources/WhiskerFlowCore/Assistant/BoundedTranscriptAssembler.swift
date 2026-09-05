import Foundation

public enum BoundedTranscriptAssemblyError: Error, Equatable {
    case missingTimings
    case emptyTranscript
}

public struct BoundedTranscriptAssembler: Sendable {
    private var segments: [TranscriptionSegment] = []

    public init() {}

    public mutating func append(
        _ result: TranscriptionResult,
        offsetSeconds: Double,
        ownership: Range<Double>,
        requiresTimings: Bool
    ) throws {
        if result.segments.isEmpty {
            if requiresTimings, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BoundedTranscriptAssemblyError.missingTimings
            }
            return
        }
        segments += result.segments.compactMap { segment in
            let midpoint = offsetSeconds + (segment.start + segment.end) / 2
            guard ownership.contains(midpoint) else { return nil }
            return TranscriptionSegment(
                text: segment.text,
                start: offsetSeconds + segment.start,
                end: offsetSeconds + segment.end
            )
        }
    }

    public func finish(language: String?, duration: Double) throws -> TranscriptionResult {
        let ordered = segments.sorted { $0.start < $1.start }
        let text = ordered.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoundedTranscriptAssemblyError.emptyTranscript }
        return TranscriptionResult(text: text, segments: ordered, language: language, duration: duration)
    }
}
