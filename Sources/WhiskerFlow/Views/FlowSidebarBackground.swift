import SwiftUI

extension View {
    /// The translucent sidebar material, or an opaque surface when the system's
    /// Reduce Transparency setting is on.
    func flowSidebarBackground() -> some View {
        modifier(FlowSidebarBackground())
    }
}

private struct FlowSidebarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency || UIPreview.reducesTransparency {
            content.background(FlowStyle.surface)
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

extension UIPreview {
    /// `--ui-reduce-transparency` renders as if Reduce Transparency were on,
    /// since a preview cannot change the system setting.
    static var reducesTransparency: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("--ui-reduce-transparency")
    }
}
