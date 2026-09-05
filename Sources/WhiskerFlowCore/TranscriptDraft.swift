import Foundation

/// An editor buffer that refuses to silently replace unsaved user work.
public struct TranscriptDraft: Equatable {
    public private(set) var recordID: UUID?
    public var text = ""
    private var sourceText = ""
    public var isDirty: Bool { text != sourceText }

    public init() {}

    @discardableResult
    public mutating func select(id: UUID, text: String) -> Bool {
        guard !isDirty else { return false }
        recordID = id
        self.text = text
        sourceText = text
        return true
    }

    public mutating func synchronize(id: UUID, text: String) {
        guard id == recordID else { return }
        let wasDirty = isDirty
        sourceText = text
        if !wasDirty { self.text = text }
    }

    public mutating func discard() { text = sourceText }
    public mutating func didSave() { sourceText = text }
}
