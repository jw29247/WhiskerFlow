import Foundation

/// Keeps surrounding document content in memory only. AX ranges use UTF-16 offsets.
public struct PastedTextScope: Sendable {
    public let original: String
    private let prefix: String
    private let suffix: String

    public init?(before: String, selection: NSRange, pasted: String) {
        guard before.utf16.count <= 65_536, !pasted.isEmpty, pasted.utf16.count <= 16_384,
              let range = Range(selection, in: before), NSRange(range, in: before) == selection,
              (range.lowerBound == before.endIndex || before.indices.contains(range.lowerBound)),
              (range.upperBound == before.endIndex || before.indices.contains(range.upperBound)) else { return nil }
        original = pasted
        prefix = String(before[..<range.lowerBound])
        suffix = String(before[range.upperBound...])
    }

    public func confirmsInsertion(_ value: String) -> Bool { value.utf16.elementsEqual((prefix + original + suffix).utf16) }

    public func editedText(in value: String) -> String? {
        guard value.utf16.count <= 65_536, value.utf16.starts(with: prefix.utf16), value.utf16.reversed().starts(with: suffix.utf16.reversed()),
              value.utf16.count >= prefix.utf16.count + suffix.utf16.count else { return nil }
        let range = NSRange(location: prefix.utf16.count,
                            length: value.utf16.count - prefix.utf16.count - suffix.utf16.count)
        guard let indices = Range(range, in: value) else { return nil }
        return String(value[indices])
    }
}
