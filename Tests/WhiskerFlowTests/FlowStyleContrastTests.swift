import XCTest
@testable import WhiskerFlow

/// WCAG 2.x contrast for the colour tokens: text needs 4.5:1 (AA).
final class FlowStyleContrastTests: XCTestCase {
    private typealias Palette = FlowStyle.Palette

    private let textTokens: [(String, Palette.Pair)] = [
        ("accent", Palette.accent), ("ink", Palette.ink), ("muted", Palette.muted),
        ("recording", Palette.recording), ("danger", Palette.danger),
        ("warning", Palette.warning), ("success", Palette.success)
    ]
    /// Every background text sits on. The floating HUD draws on `surface`.
    private let backgrounds: [(String, Palette.Pair)] = [
        ("canvas", Palette.canvas), ("surface", Palette.surface), ("selection", Palette.selection)
    ]

    func testTextTokensReachAAOnEveryBackground() {
        for (token, text) in textTokens {
            for (background, fill) in backgrounds {
                assertAA(text.light, on: fill.light, "\(token) on \(background), light")
                assertAA(text.dark, on: fill.dark, "\(token) on \(background), dark")
            }
        }
    }

    /// `FlowPrimaryButtonStyle`: its label on the normal and destructive
    /// fills, at rest and pressed (the fill darkened by 15% black).
    func testPrimaryButtonLabelReachesAA() {
        for (variant, fill) in [("primary", Palette.accent), ("destructive", Palette.recording)] {
            for (appearance, label, colour) in [("light", Palette.onAccent.light, fill.light),
                                                ("dark", Palette.onAccent.dark, fill.dark)] {
                assertAA(label, on: colour, "\(variant) button, \(appearance)")
                assertAA(label, on: darkened(colour, by: FlowPrimaryButtonStyle.pressedShade),
                         "\(variant) button pressed, \(appearance)")
            }
        }
    }

    func testContrastFormulaMatchesKnownValues() {
        XCTAssertEqual(Self.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(Self.contrast(0x777777, 0xFFFFFF), 4.48, accuracy: 0.01)
    }

    private func assertAA(_ text: UInt32, on background: UInt32, _ label: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let ratio = Self.contrast(text, background)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, String(format: "%@: %.2f:1", label, ratio), file: file, line: line)
    }

    private func darkened(_ hex: UInt32, by amount: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let channel = Double((hex >> UInt32(shift)) & 255) * (1 - amount)
            return result | (UInt32(channel.rounded()) << UInt32(shift))
        }
    }

    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}
