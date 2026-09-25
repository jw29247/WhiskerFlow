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
    guard width > 0, height > 0, width <= 4096, height <= 4096, nameHeight >= 8 else { return [] }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let c = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
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
    for start in mask.indices where mask[start] == 1 {
      var stack = [start]
      var minX = width
      var maxX = 0
      var minY = height
      var maxY = 0
      mask[start] = 0
      while let i = stack.popLast() {
        let x = i % width
        let y = i / width
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        // Eight-connected: anti-aliased rounded corners can be diagonal.
        for dy in -1...1 {
          for dx in -1...1 where dx != 0 || dy != 0 {
            let nx = x + dx
            let ny = y + dy
            if nx >= 0 && nx < width && ny >= 0 && ny < height {
              let next = ny * width + nx
              if mask[next] == 1 {
                mask[next] = 0
                stack.append(next)
              }
            }
          }
        }
      }
      let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      guard rect.width >= 120 * scale, rect.height >= 90 * scale else { continue }
      if isSpeaking(image: image, tile: rect, scale: scale) { matches.append(rect) }
    }
    return matches
  }

  public static func isSpeaking(image: CGImage, tile: CGRect, scale: CGFloat = 1) -> Bool {
    guard scale > 0, tile.width >= 120 * scale, tile.height >= 90 * scale,
      CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(tile),
      image.width <= 4096, image.height <= 4096
    else { return false }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &bytes, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
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
