import CoreGraphics
import Foundation

/// Evaluates only the border and activity badge of an AX-identified video tile.
/// Frames stay in memory. A blue focus border alone is never speaking evidence.
public enum MeetingVisualActivity {
  /// AX exposes the name's bounds, but Meet hides video-tile bounds. Locate
  /// the actual connected speaking outline in pixels, then bind only a name
  /// physically inside its bottom-left corner. Never infer roster ordering.
  public static func speakingTile(image: CGImage, nameFrame: CGRect) -> CGRect? {
    let matches = speakingTiles(image: image, nameHeight: nameFrame.height).filter { rect in
      rect.contains(nameFrame) && nameFrame.minX < rect.minX + rect.width * 0.25
        && nameFrame.minY > rect.minY + rect.height * 0.65
    }
    return matches.count == 1 ? matches[0] : nil
  }

  public static func speakingTiles(image: CGImage, nameHeight: CGFloat) -> [CGRect] {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, width <= 4096, height <= 4096, nameHeight >= 8,
      let bytes = rasterize(image)
    else { return [] }
    var mask = [UInt8](repeating: 0, count: width * height)
    for i in mask.indices {
      let r = Int(bytes[i * 4])
      let g = Int(bytes[i * 4 + 1])
      let b = Int(bytes[i * 4 + 2])
      if r >= 100 && r <= 205 && g >= 155 && g <= 230 && b >= 200 && b > r + 25 && g > r + 8 {
        mask[i] = 1
      }
    }
    let scale = nameHeight / 13
    var matches: [CGRect] = []
    // Scanline fill: the stack holds one seed per run, not one per pixel, so
    // a large blue region (shared slide, background) stays cheap.
    var stack: [Int] = []
    for start in mask.indices where mask[start] == 1 {
      stack.removeAll(keepingCapacity: true)
      stack.append(start)
      var minX = width
      var maxX = 0
      var minY = height
      var maxY = 0
      while let seed = stack.popLast() {
        let y = seed / width
        let row = y * width
        var left = seed % width
        guard mask[row + left] == 1 else { continue }
        var right = left
        while left > 0 && mask[row + left - 1] == 1 { left -= 1 }
        while right < width - 1 && mask[row + right + 1] == 1 { right += 1 }
        for x in left...right { mask[row + x] = 0 }
        minX = min(minX, left)
        maxX = max(maxX, right)
        minY = min(minY, y)
        maxY = max(maxY, y)
        // Eight-connected: anti-aliased rounded corners can be diagonal.
        let lower = max(0, left - 1)
        let upper = min(width - 1, right + 1)
        for ny in [y - 1, y + 1] where ny >= 0 && ny < height {
          let next = ny * width
          var inRun = false
          for x in lower...upper {
            if mask[next + x] == 1 {
              if !inRun { stack.append(next + x) }
              inRun = true
            } else {
              inRun = false
            }
          }
        }
      }
      let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      guard rect.width >= 120 * scale, rect.height >= 90 * scale else { continue }
      if isSpeaking(bytes: bytes, width: width, height: height, tile: rect, scale: scale) {
        matches.append(rect)
      }
    }
    return matches
  }

  public static func isSpeaking(image: CGImage, tile: CGRect, scale: CGFloat = 1) -> Bool {
    guard image.width <= 4096, image.height <= 4096, let bytes = rasterize(image) else { return false }
    return isSpeaking(bytes: bytes, width: image.width, height: image.height, tile: tile, scale: scale)
  }

  /// RGBA8 premultiplied, top row first. Drawn once per frame and shared by
  /// every candidate tile.
  private static func rasterize(_ image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? bytes : nil
  }

  static func isSpeaking(bytes: [UInt8], width: Int, height: Int, tile: CGRect, scale: CGFloat)
    -> Bool
  {
    guard scale > 0, tile.width >= 120 * scale, tile.height >= 90 * scale,
      CGRect(x: 0, y: 0, width: width, height: height).contains(tile),
      bytes.count >= width * height * 4
    else { return false }
    func pixel(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
      let px = max(0, min(width - 1, Int(x)))
      let py = max(0, min(height - 1, Int(y)))
      let i = (py * width + px) * 4
      return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
    func blue(_ x: CGFloat, _ y: CGFloat) -> Bool {
      let (r, g, b) = pixel(x, y)
      return r >= 100 && r <= 205 && g >= 155 && g <= 230 && b >= 200 && b > r + 25 && g > r + 8
    }
    // Require long opposing edges, excluding rounded corners and name text.
    func edge(left: Bool) -> Bool {
      (0..<20).filter { sample in
        let y = tile.minY + tile.height * (0.12 + CGFloat(sample) * 0.038)
        return (0...4).contains { inset in
          blue(
            left ? tile.minX + CGFloat(inset) * scale : tile.maxX - 1 - CGFloat(inset) * scale, y)
        }
      }.count >= 16
    }
    guard edge(left: true), edge(left: false) else { return false }
    // Meet's speaking badge is a blue disc with a dark waveform, inset at
    // the top-right of the SAME tile. Muted icons and plain borders fail.
    let cx = tile.maxX - 17 * scale
    let cy = tile.minY + 17 * scale
    var blueCount = 0
    var inkCount = 0
    for y in -7...7 {
      for x in -7...7 {
        let px = cx + CGFloat(x) * scale
        let py = cy + CGFloat(y) * scale
        if blue(px, py) { blueCount += 1 }
        let (r, g, b) = pixel(px, py)
        if abs(x) <= 5 && abs(y) <= 5 && r < 100 && g < 140 && b < 190 && b > r { inkCount += 1 }
      }
    }
    return blueCount >= 90 && inkCount >= 5 && inkCount <= 80
  }
}
