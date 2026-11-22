import AppKit
import SwiftUI

/// The shared visual language for the window, popover, setup and recording HUD.
enum FlowStyle {
    static let accent = adaptive(Palette.accent)
    static let ink = adaptive(Palette.ink)
    static let muted = adaptive(Palette.muted)
    static let canvas = adaptive(Palette.canvas)
    static let surface = adaptive(Palette.surface)
    static let line = adaptive(Palette.line)
    static let selection = adaptive(Palette.selection)
    /// The microphone is live.
    static let recording = adaptive(Palette.recording)
    /// Something went wrong and needs the user. Warmer than `recording`, so a
    /// failure is never mistaken for a live microphone.
    static let danger = adaptive(Palette.danger)
    /// A caution or a missing permission: worth attention, nothing has failed.
    static let warning = adaptive(Palette.warning)
    /// Done or granted.
    static let success = adaptive(Palette.success)
    /// Text and icons on an `accent` or `recording` fill.
    static let onAccent = adaptive(Palette.onAccent)

    /// The sRGB values behind each token. Every text token reaches 4.5:1 on
    /// `canvas`, `surface` and `selection` in both appearances; the contrast
    /// test checks it.
    enum Palette {
        typealias Pair = (light: UInt32, dark: UInt32)
        static let accent: Pair = (0x335DE8, 0x88A4FF)
        static let ink: Pair = (0x17243A, 0xE9EDF7)
        static let muted: Pair = (0x5E6B81, 0xA7B2C6)
        static let canvas: Pair = (0xF5F7FA, 0x191D27)
        static let surface: Pair = (0xFFFFFF, 0x232936)
        static let line: Pair = (0xDDE3ED, 0x343D4F)
        static let selection: Pair = (0xE6ECFB, 0x2C395C)
        static let recording: Pair = (0xC03747, 0xFF8590)
        static let danger: Pair = (0xBD3F0C, 0xFFA06E)
        static let warning: Pair = (0x906000, 0xE3B341)
        static let success: Pair = (0x147A3A, 0x4ADE80)
        static let onAccent: Pair = (0xFFFFFF, 0x101522)
    }

    private static func adaptive(_ pair: Palette.Pair) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
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

/// Reads the input level in its own body: the level changes with every audio
/// buffer (~10 Hz), and reading it in a parent would rebuild the whole screen.
struct LiveFlowWaveform: View {
    let appState: AppState
    var recording: Bool
    var size: CGFloat

    var body: some View {
        FlowWaveform(level: appState.audioLevel, recording: recording, size: size)
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
    var color: Color = FlowStyle.success

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
    /// Pressed darkens the fill rather than fading the button: fading took
    /// the light-mode label below 4.5:1.
    static let pressedShade = 0.15
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(FlowStyle.onAccent)
            .background(RoundedRectangle(cornerRadius: 8).fill(destructive ? FlowStyle.recording : FlowStyle.accent)
                .overlay(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(configuration.isPressed ? Self.pressedShade : 0))))
            .opacity(isEnabled ? 1 : 0.4)
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
