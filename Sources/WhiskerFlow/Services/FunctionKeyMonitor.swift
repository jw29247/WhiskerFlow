import AppKit

@MainActor
final class FunctionKeyMonitor {
    private let onChange: (Bool) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func handle(_ event: NSEvent) {
        let functionIsPressed = event.modifierFlags.contains(.function)
        guard functionIsPressed != isPressed else { return }

        isPressed = functionIsPressed
        onChange(functionIsPressed)
    }
}
