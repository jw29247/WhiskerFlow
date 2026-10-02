import Foundation

/// Keeps surrounding document content in memory only. AX ranges use UTF-16 offsets.
public struct PastedTextScope: Sendable {
    public let original: String
    private let prefix: String
    private let suffix: String
    /// An empty Chromium rich-text editor (Slack, Claude, T3 Code, Gmail)
    /// reports its lone paragraph break as "\n", and drops it once text lands,
    /// or keeps it on some editors, so either form counts.
    private let emptyEditor: Bool

    public init?(before: String, selection: NSRange, pasted: String) {
        guard before.utf16.count <= 65_536, !pasted.isEmpty, pasted.utf16.count <= 16_384,
              let range = Range(selection, in: before), NSRange(range, in: before) == selection,
              (range.lowerBound == before.endIndex || before.indices.contains(range.lowerBound)),
              (range.upperBound == before.endIndex || before.indices.contains(range.upperBound)) else { return nil }
        original = pasted
        emptyEditor = before == "\n" && selection == NSRange(location: 0, length: 0)
        prefix = emptyEditor ? "" : String(before[..<range.lowerBound])
        suffix = emptyEditor ? "" : String(before[range.upperBound...])
    }

    public func confirmsInsertion(_ value: String) -> Bool {
        normalized(value).utf16.elementsEqual((prefix + original + suffix).utf16)
    }

    private func normalized(_ value: String) -> String {
        emptyEditor && value.hasSuffix("\n") && !original.hasSuffix("\n") ? String(value.dropLast()) : value
    }

    public func editedText(in value: String) -> String? {
        let value = normalized(value)
        guard value.utf16.count <= 65_536, value.utf16.starts(with: prefix.utf16), value.utf16.reversed().starts(with: suffix.utf16.reversed()),
              value.utf16.count >= prefix.utf16.count + suffix.utf16.count else { return nil }
        let range = NSRange(location: prefix.utf16.count,
                            length: value.utf16.count - prefix.utf16.count - suffix.utf16.count)
        guard let indices = Range(range, in: value) else { return nil }
        return String(value[indices])
    }
}
