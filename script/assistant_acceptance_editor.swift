import AppKit

@main
final class FixtureEditor: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureEditor()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 760, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "WhiskerFlow · Synthetic acceptance editor"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 18)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.autoresizingMask = [.width, .height]
        text.string = "Please send the report to Mark before Friday."
        text.setAccessibilityIdentifier("synthetic-editor")
        scroll.documentView = text
        window.contentView!.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
