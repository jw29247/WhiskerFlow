import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the WhiskerFlow app icon (rounded gradient tile + white waveform) to
// an .iconset folder. Pure Core Graphics so it runs headless in CI.

func makeIcon(size: Int, url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    let s = CGFloat(size)
    let rect = CGRect(x: s * 0.05, y: s * 0.05, width: s * 0.90, height: s * 0.90)
    let radius = s * 0.225
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let colors = [
        CGColor(red: 0.49, green: 0.36, blue: 0.98, alpha: 1),
        CGColor(red: 0.29, green: 0.20, blue: 0.76, alpha: 1)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    let heights: [CGFloat] = [0.28, 0.50, 0.78, 0.50, 0.28]
    let barWidth = s * 0.085
    let gap = s * 0.05
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (s - totalWidth) / 2
    for h in heights {
        let barHeight = s * h
        let barRect = CGRect(x: x, y: (s - barHeight) / 2, width: barWidth, height: barHeight)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for entry in entries {
    makeIcon(size: entry.px, url: outputDir.appendingPathComponent("\(entry.name).png"))
}
print("Wrote iconset to \(outputDir.path)")
