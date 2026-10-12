#if DEBUG
import AppKit

/// Debug-only visual QA: renders the app's own main window to a PNG when a
/// local tool posts `agency.thatworks.WhiskerFlow.debug.snapshotWindow` with
/// the output path as the notification object. The app draws its own view
/// hierarchy, so no Screen Recording grant is used and no other app's pixels
/// are read. Release builds do not contain this code.
@MainActor
enum DebugWindowSnapshot {
    static let notificationName = Notification.Name("agency.thatworks.WhiskerFlow.debug.snapshotWindow")
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { notification in
            // "path" snapshots the main window; "path|title" a window by title
            // (the floating coach and call-prompt panels).
            guard let object = notification.object as? String else { return }
            let parts = object.split(separator: "|", maxSplits: 1).map(String.init)
            guard let path = parts.first, path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return }
            MainActor.assumeIsolated { snapshot(to: URL(fileURLWithPath: path), title: parts.count > 1 ? parts[1] : nil) }
        }
    }

    private static func snapshot(to url: URL, title: String?) {
        let window: NSWindow?
        if let title, title != "content" {
            window = NSApp.windows.first { $0.isVisible && $0.title == title }
        } else {
            window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        }
        guard let window, var view = window.contentView?.superview ?? window.contentView else { return }
        // "content" renders the main window's largest scroll view in full.
        if title == "content" {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
            }
            guard let document = scrollViews(in: view)
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.documentView else { return }
            view = document
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
