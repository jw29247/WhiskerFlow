import AppKit
import Foundation
import OpenTelemetryApi
import ScreenCaptureKit
import WhiskerFlowAppSupport

/// Window-scoped, on-device fallback for Meet's visible tile activity.
/// No pixels or participant names enter logs, telemetry, disk or network.
enum MeetingVisualSpeakerReader {
  @MainActor static func read(_ snapshot: MeetingAccessibilitySnapshot) async
    -> MeetingAccessibilitySnapshot?
  {
    guard let pid = snapshot.processID, let frame = snapshot.windowFrame,
      !snapshot.visualTiles.isEmpty, snapshot.visualTiles.count <= 60,
      CGPreflightScreenCaptureAccess()
    else { return nil }
    let span = Observability.tracer.spanBuilder(spanName: "meeting.observe_visual_activity")
      .startSpan()
    defer { span.end() }
    var succeeded = false
    defer { if !succeeded { span.status = .error(description: "capture_unavailable") } }
    do {
      guard
        let content: SCShareableContent = await boundedRead({ finish in
          SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) {
            value, _ in finish(value)
          }
        })
      else { return nil }
      let windows = content.windows.filter {
        $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
          && abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2
          && abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
      }
      guard windows.count == 1, let window = windows.first else { return nil }
      let config = SCStreamConfiguration()
      let captureScale = min(1, 2048 / max(frame.width, frame.height))
      config.width = max(1, Int(frame.width * captureScale))
      config.height = max(1, Int(frame.height * captureScale))
      config.showsCursor = false
      config.ignoreShadowsSingleWindow = true
      guard
        let image: CGImage = await boundedRead({ finish in
          SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
          ) { value, _ in finish(value) }
        })
      else { return nil }
      guard !Task.isCancelled else { return nil }
      let worker = Task.detached(priority: .utility) {
        // Reject a changed tab, moved/resized window or renamed/recycled tile
        // between the accessibility observation and screenshot completion.
        guard let fresh = MeetingAccessibilityReader.read(pids: [pid]).snapshot,
          fresh.meetingID == snapshot.meetingID, fresh.windowFrame == snapshot.windowFrame,
          fresh.visualTiles.count == snapshot.visualTiles.count,
          snapshot.visualTiles.allSatisfy({ tile in
            fresh.visualTiles.contains {
              $0.id == tile.id && $0.name == tile.name && $0.frame == tile.frame
            }
          })
        else { return nil as MeetingAccessibilitySnapshot? }
        var result = snapshot
        result.speakers = [:]
        let sx = CGFloat(image.width) / frame.width
        let sy = CGFloat(image.height) / frame.height
        guard abs(sx - sy) < 0.02 else { return result }
        // Duplicate displayed names or overlapping candidate tiles are ambiguous.
        let counts = Dictionary(grouping: snapshot.visualTiles, by: \.name)
        let heights = snapshot.visualTiles.map { $0.frame.height * sy }.sorted()
        let outlines = MeetingVisualActivity.speakingTiles(
          image: image, nameHeight: heights[heights.count / 2])
        #if DEBUG
        if CommandLine.arguments.contains("--probe-native-meet") {
          print("meet_probe outlines=\(outlines.count) name_height=\(heights[heights.count/2]) image=\(image.width)x\(image.height)")
        }
        #endif
        for tile in snapshot.visualTiles where counts[tile.name]?.count == 1 {
          guard
            !snapshot.visualTiles.contains(where: {
              $0.id != tile.id && $0.frame.intersects(tile.frame)
            })
          else { continue }
          let rect = CGRect(
            x: (tile.frame.minX - frame.minX) * sx,
            y: (tile.frame.minY - frame.minY) * sy,
            width: tile.frame.width * sx, height: tile.frame.height * sy)
          let matching = outlines.filter {
            $0.contains(rect) && rect.minX < $0.minX + $0.width * 0.25
              && rect.minY > $0.minY + $0.height * 0.65
          }
          if matching.count == 1, let speakingTile = matching.first {
            let inside = snapshot.visualTiles.filter {
              let nameRect = CGRect(
                x: ($0.frame.minX - frame.minX) * sx, y: ($0.frame.minY - frame.minY) * sy,
                width: $0.frame.width * sx, height: $0.frame.height * sy)
              return speakingTile.contains(nameRect)
            }
            if inside.count == 1 { result.speakers["visual:" + tile.id] = tile.name }
          }
        }
        return result
      }
      let result = await worker.value
      span.setAttribute(key: "speaker.active_count", value: result?.speakers.count ?? 0)
      succeeded = result != nil
      return result
    }
  }
  private static func boundedRead<T>(_ start: (@escaping (T?) -> Void) -> Void) async -> T? {
    await withCheckedContinuation { continuation in
      let once = VisualReadCompletion(continuation)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { once.finish(nil) }
      start { once.finish($0) }
    }
  }

}

private final class VisualReadCompletion<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T?, Never>?
  init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
  func finish(_ value: T?) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: value)
  }
}
