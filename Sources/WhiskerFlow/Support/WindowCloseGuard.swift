import AppKit
import SwiftUI

/// Preserve SwiftUI's window delegate while adding a native unsaved-edit guard.
struct WindowCloseGuard: NSViewRepresentable {
    var isDirty: Bool
    var save: () -> Bool
    var discard: () -> Void
    private static let guards = NSHashTable<Coordinator>.weakObjects()

    static func confirmTermination() -> Bool {
        guards.allObjects.allSatisfy { $0.confirmDiscardOrSave() }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        Self.guards.add(coordinator)
        return coordinator
    }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.save = save
        context.coordinator.discard = discard
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let window = coordinator.window, window.delegate === coordinator { window.delegate = coordinator.original }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        var isDirty = false
        var save: (() -> Bool)?
        var discard: (() -> Void)?
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            confirmDiscardOrSave() && (original?.windowShouldClose?(sender) ?? true)
        }
        func confirmDiscardOrSave() -> Bool {
            guard isDirty else { return true }
            let alert = NSAlert()
            alert.messageText = "Save your changes?"
            alert.informativeText = "This transcript has unsaved changes."
            alert.addButton(withTitle: "Save changes")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard changes")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let saved = save?() ?? false
                if saved { isDirty = false }
                return saved
            case .alertThirdButtonReturn:
                discard?()
                isDirty = false
                return true
            default: return false
            }
        }
    }
}
