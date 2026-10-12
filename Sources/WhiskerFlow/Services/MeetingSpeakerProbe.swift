#if DEBUG
  import AppKit
  import Foundation
  import WhiskerFlowAppSupport

  /// Opt-in, read-only diagnostic entry point. Never starts audio, creates AppState,
  /// changes Meet controls, writes speaker evidence or retains frames/names.
  enum MeetingSpeakerProbe {
    @MainActor static func runAndExit() -> Never {
      _ = NSApplication.shared
      NSApp.setActivationPolicy(.prohibited)
      Task { @MainActor in
        let pids = NSWorkspace.shared.runningApplications.filter {
          $0.bundleIdentifier == "com.google.Chrome"
            || $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        }.map(\.processIdentifier)
        var timeline = MeetingAccessibilityTimeline()
        let epoch = ProcessInfo.processInfo.systemUptime
        var rowCount = 0
        for _ in 0..<10 {
          let start = ProcessInfo.processInfo.systemUptime
          let result = await Task.detached(priority: .utility) {
            MeetingAccessibilityReader.read(pids: pids)
          }.value
          let visual =
            if let snapshot = result.snapshot {
              await MeetingVisualSpeakerReader.read(snapshot)
            } else {
              nil as WhiskerFlowAppSupport.MeetingAccessibilitySnapshot?
            }
          let atMs = Int64((ProcessInfo.processInfo.systemUptime - epoch) * 1000)
          rowCount += timeline.observe(visual, atMs: atMs).count
          print(
            "meet_probe timeline_rows=\(rowCount) snapshot=\(result.snapshot != nil) tiles=\(result.snapshot?.visualTiles.count ?? 0) visual_valid=\(visual != nil) speaking=\(visual?.speakers.count ?? 0) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) reason=\(result.unavailableDetail)"
          )
          fflush(stdout)
          try? await Task.sleep(nanoseconds: 750_000_000)
        }
        exit(0)
      }
      let deadline = Date().addingTimeInterval(30)
      while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      print("meet_probe timeout")
      exit(2)
    }
  }
#endif
