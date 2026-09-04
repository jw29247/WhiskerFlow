import AppKit
import SwiftUI

/// The shared visual language for the window, popover, setup and recording HUD.
enum FlowStyle {
    static let accent = adaptive(light: 0x365FE8, dark: 0x88A4FF)
    static let ink = adaptive(light: 0x17243A, dark: 0xE9EDF7)
    static let muted = adaptive(light: 0x637087, dark: 0xA7B2C6)
    static let canvas = adaptive(light: 0xF5F7FA, dark: 0x191D27)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x232936)
    static let line = adaptive(light: 0xDDE3ED, dark: 0x343D4F)
    static let selection = adaptive(light: 0xE6ECFB, dark: 0x2C395C)
    static let recording = adaptive(light: 0xC94352, dark: 0xFF8590)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct FlowWaveform: View {
    var level: Float = 0
    var recording = false
    var size: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heights: [CGFloat] = [0.16, 0.42, 0.72, 1, 0.72, 0.42, 0.16]

    var body: some View {
        HStack(spacing: size * 0.075) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(recording ? FlowStyle.recording : FlowStyle.accent)
                    .frame(width: size * 0.065, height: height(at: index))
            }
        }
        .frame(width: size * 1.05, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        let amplitude = recording ? max(0.2, min(1, CGFloat(level) * 5)) : 1
        return max(3, heights[index] * size * amplitude)
    }
}

struct FlowKeycap: View {
    let title: String
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if title == "fn (Globe)" { Image(systemName: "globe"); Text("fn") }
            else { Text(title) }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .font(.system(size: compact ? 12 : 21, weight: .medium, design: .rounded))
            .foregroundStyle(FlowStyle.ink)
            .padding(.horizontal, compact ? 9 : 18)
            .padding(.vertical, compact ? 5 : 10)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: compact ? 6 : 9))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 9).stroke(FlowStyle.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 2)
    }
}

struct FlowStatus: View {
    let title: String
    var color: Color = .green

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12))
        }
        .foregroundStyle(FlowStyle.muted)
        .accessibilityElement(children: .combine)
    }
}

struct FlowPrimaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(Color.white)
            .background(destructive ? FlowStyle.recording : Color(red: 0.21, green: 0.36, blue: 0.88),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct FlowCopyButton: View {
    let text: String
    var compact = false
    var allowsEmpty = false
    var copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy(text)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(FlowCopyLabelStyle(compact: compact))
        }
        .accessibilityLabel(copied ? "Copied" : "Copy text")
        .disabled(text.isEmpty && !allowsEmpty)
        .help(copied ? "Copied to clipboard" : "Copy text")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}

private struct FlowCopyLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

struct FlowEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(FlowStyle.accent)
            Text(title).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(FlowStyle.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
