import SwiftUI

private struct ShowScreenKey: FocusedValueKey {
    typealias Value = (FlowDestination) -> Void
}

extension FocusedValues {
    /// Opens a screen in the focused main window, through its unsaved-edits check.
    var showScreen: ((FlowDestination) -> Void)? {
        get { self[ShowScreenKey.self] }
        set { self[ShowScreenKey.self] = newValue }
    }
}

/// ⌘1 – ⌘7 in the View menu. The sidebar is a list, whose rows can't carry
/// shortcuts, so the screens are menu items as in other Mac apps.
struct ScreenCommands: Commands {
    @FocusedValue(\.showScreen) private var showScreen

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            ForEach(FlowDestination.allCases) { item in
                Button(item.rawValue) { showScreen?(item) }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(showScreen == nil)
            }
            Divider()
        }
    }
}
