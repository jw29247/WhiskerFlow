import SwiftUI

private struct CopyTranscriptKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyTranscript: (() -> Void)? {
        get { self[CopyTranscriptKey.self] }
        set { self[CopyTranscriptKey.self] = newValue }
    }
}

struct TranscriptCommands: Commands {
    @FocusedValue(\.copyTranscript) private var copyTranscript
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy Transcript") { copyTranscript?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyTranscript == nil)
        }
    }
}
