import AppKit
import Foundation
import OpenTelemetryApi
import ScreenCaptureKit
import WhiskerFlowAppSupport

/// One in-memory window frame awaiting confirmation by a later AX read.
struct MeetingVisualFrame: @unchecked Sendable {
  let snapshot: MeetingAccessibilitySnapshot
  let image: CGImage
  /// Epoch milliseconds when ScreenCaptureKit delivered the frame.
  let capturedAtMs: Int64
}

/// Window-scoped, on-device fallback for Meet's visible tile activity.
/// No pixels or participant names enter logs, telemetry, disk or network.
enum MeetingVisualSpeakerReader {
  /// Per-request ScreenCaptureKit budget. Window enumeration alone can take
  /// several hundred milliseconds on a base M1 or Intel Mac.
  static let requestTimeoutSeconds: Double = 1.0
  /// A cached window is re-enumerated after this long so a hidden, minimised
  /// or replaced window is not captured indefinitely.
  static let windowCacheSeconds: TimeInterval = 5
  @MainActor private static var cachedWindow:
    (pid: Int32, frame: CGRect, window: SCWindow, fetchedAt: TimeInterval)?
  private static let requestGate = VisualRequestGate()

  /// Capture, confirm with a fresh AX read, then analyse. The recording loop
  /// instead confirms with its next scheduled read (see `capture`/`analyze`).
  @MainActor static func read(_ snapshot: MeetingAccessibilitySnapshot) async
    -> MeetingAccessibilitySnapshot?
  {
    guard let pid = snapshot.processID, let frame = await capture(snapshot) else { return nil }
    return await Task.detached(priority: .utility) {
      guard let fresh = MeetingAccessibilityReader.read(pids: [pid]).snapshot else {
        return nil as MeetingAccessibilitySnapshot?
      }
      return analyze(frame, verifiedBy: fresh)
    }.value
  }

  @MainActor static func capture(_ snapshot: MeetingAccessibilitySnapshot) async
    -> MeetingVisualFrame?
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
    guard let window = await shareableWindow(pid: pid, frame: frame) else { return nil }
    let config = SCStreamConfiguration()
    let captureScale = min(1, 2048 / max(frame.width, frame.height))
    config.width = max(1, Int(frame.width * captureScale))
    config.height = max(1, Int(frame.height * captureScale))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    guard
      let captured: (CGImage, Int64) = await boundedRead({ finish in
        SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
        ) { value, _ in finish(value.map { ($0, Int64(Date().timeIntervalSince1970 * 1000)) }) }
      })
    else {
      cachedWindow = nil
      return nil
    }
    guard !Task.isCancelled else { return nil }
    succeeded = true
    return .init(snapshot: snapshot, image: captured.0, capturedAtMs: captured.1)
  }

  @MainActor private static func shareableWindow(pid: Int32, frame: CGRect) async -> SCWindow? {
    let now = ProcessInfo.processInfo.systemUptime
    if let cached = cachedWindow, cached.pid == pid, cached.frame == frame,
      now - cached.fetchedAt < windowCacheSeconds, isOnScreen(cached.window.windowID)
    {
      return cached.window
    }
    cachedWindow = nil
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
    cachedWindow = (pid, frame, window, now)
    return window
  }

  /// Minimising, hiding or moving the window to another Space leaves its AX
  /// frame unchanged, so a cached window is re-checked before every capture.
  private static func isOnScreen(_ windowID: CGWindowID) -> Bool {
    guard
      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
        as? [[String: Any]], let entry = info.first
    else { return false }
    return entry[kCGWindowIsOnscreen as String] as? Bool ?? false
  }

  /// Pure and off-main. `fresh` must be an AX read completed after the frame.
  static func analyze(_ captured: MeetingVisualFrame, verifiedBy fresh: MeetingAccessibilitySnapshot)
    -> MeetingAccessibilitySnapshot?
  {
    let snapshot = captured.snapshot
    let image = captured.image
    guard let frame = snapshot.windowFrame else { return nil }
    // Reject a changed tab, moved/resized window or renamed/recycled tile
    // between the accessibility observation and screenshot completion.
    guard fresh.meetingID == snapshot.meetingID, fresh.windowFrame == snapshot.windowFrame,
      fresh.visualTiles.count == snapshot.visualTiles.count,
      snapshot.visualTiles.allSatisfy({ tile in
        fresh.visualTiles.contains {
          $0.id == tile.id && $0.name == tile.name && $0.frame == tile.frame
        }
      })
    else { return nil }
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

  /// ScreenCaptureKit requests cannot be cancelled. A timed-out request keeps
  /// the gate closed until it really completes, so slow captures never stack.
  private static func boundedRead<T>(_ start: (@escaping (T?) -> Void) -> Void) async -> T? {
    guard requestGate.begin() else { return nil }
    return await withCheckedContinuation { continuation in
      let once = VisualReadCompletion(continuation)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeoutSeconds) {
        once.finish(nil)
      }
      start { value in
        requestGate.end()
        once.finish(value)
      }
    }
  }

}

private final class VisualRequestGate: @unchecked Sendable {
  /// A request that never calls back must not disable the fallback for good.
  private static let abandonAfterSeconds: TimeInterval = 10
  private let lock = NSLock()
  private var startedAt: TimeInterval?
  func begin() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    if let startedAt, now - startedAt < Self.abandonAfterSeconds { return false }
    startedAt = now
    return true
  }
  func end() {
    lock.lock()
    startedAt = nil
    lock.unlock()
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
