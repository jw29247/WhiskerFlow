import Foundation
import Logging

/// A bounded, asynchronous local backend for explicitly allowlisted diagnostic events.
/// Message bodies, errors, source locations and arbitrary metadata are never persisted.
final class LocalDiagnosticLog: @unchecked Sendable {
    static let shared = LocalDiagnosticLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WhiskerFlow"))
    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "WhiskerFlow.local-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private let launch = UUID().uuidString
    private let build = Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowBuildRevision") as? String ?? "development"
    init(directory: URL, maxBytes: Int = 2_000_000) { self.directory = directory; self.maxBytes = maxBytes }

    func append(_ fields: [String: String]) {
        lock.lock()
        guard pending < 512 else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        var row = fields
        row["timestamp"] = String(Date().timeIntervalSince1970)
        row["uptime"] = String(ProcessInfo.processInfo.systemUptime)
        row["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        row["launch"] = launch
        row["build"] = build
        guard let encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
            lock.lock(); pending -= 1; lock.unlock(); return
        }
        let data = encoded + Data([10])
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard data.count <= maxBytes else { return }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("diagnostics.jsonl")
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                if size + data.count > maxBytes {
                    let older = directory.appendingPathComponent("diagnostics.2.jsonl")
                    let previous = directory.appendingPathComponent("diagnostics.1.jsonl")
                    if fm.fileExists(atPath: older.path) { try fm.removeItem(at: older) }
                    if fm.fileExists(atPath: previous.path) { try fm.moveItem(at: previous, to: older) }
                    if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: previous) }
                }
                if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics must never block or fail dictation; unified log remains available.
            }
        }
    }
    func flush() { queue.sync {} }
}

struct LocalDiagnosticLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?
    var logLevel: Logging.Logger.Level = .info
    let label: String
    let sink: LocalDiagnosticLog
    init(label: String, sink: LocalDiagnosticLog = .shared) { self.label = label; self.sink = sink }
    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        guard ["agency.thatworks.WhiskerFlow.DictationLifecycle", "agency.thatworks.WhiskerFlow.MeetingProcessing"].contains(label) else { return }
        var values = metadata
        if let extra = event.metadata { values.merge(extra) { _, new in new } }
        let allowedEvents: Set<String> = ["meeting_window_empty", "meeting_speaker_probe", "app_started", "state_changed", "recording_requested", "recording_rejected", "recording_started", "finish_started", "decode_returned", "paste_started", "paste_posted", "paste_returned", "finish_returned", "finish_timeout", "capture_discarded", "main_thread_stalled", "main_thread_recovered", "heartbeat", "stage_started", "stage_finished", "resource_snapshot", "stack_capture_started", "stack_captured", "stack_capture_failed", "call_detection_started", "call_detected", "call_ended", "call_unrecognised", "correction_watch", "correction_observed", "dictionary_learned", "capture_engine_timeout"]
        guard let name = values["event"]?.description, allowedEvents.contains(name) else { return }
        var fields = ["event": name, "level": event.level.rawValue]
        for key in ["window_start_ms", "window_end_ms", "worker_elapsed_ms", "resume_delay_ms", "sample_report_bytes", "sample_thread_headers", "sample_main_headers", "sample_symbol_lines", "elapsed_ms", "pending", "samples", "conversion_failures", "speaker_count", "visual_tile_count", "load_1m", "cpu_count", "app_cpu_percent", "system_cpu_percent", "sample_interval_ms", "rss_bytes", "swap_used_bytes", "swapins_pages", "swapouts_pages", "swapins_delta_pages", "swapouts_delta_pages", "compressed_pages", "page_size_bytes", "window_sources", "titles", "titles_with_meet", "titles_with_code", "corrections", "learned"] {
            if let value = values[key]?.description, let number = Double(value), number.isFinite, number >= 0 { fields[key] = value }
        }
        for key in ["recording", "transcribing", "visual_read_failed", "accessibility", "voice_processing"] {
            if let value = values[key]?.description, ["true", "false"].contains(value) { fields[key] = value }
        }
        if let value = values["session"]?.description, UUID(uuidString: value) != nil { fields["session"] = value }
        if let value = values["capture_id"]?.description, UUID(uuidString: value) != nil { fields["capture_id"] = value }
        let states: Set<String> = ["idle", "preparing", "recording", "transcribing", "delivering", "success", "failure", "verified", "unverified", "copied", "failed", "confirmed", "unconfirmed"]
        for key in ["state", "outcome"] {
            if let value = values[key]?.description, states.contains(value) { fields[key] = value }
        }
        let categories: [String: Set<String>] = [
            "track": ["microphone", "system", "mixed"],
            "capture_failure": ["no_frames", "launch_failed", "terminated", "nonzero_exit", "write_failed"],
            "stage": ["recognition", "text_processing", "history_save", "ui_update", "completion_sound"],
            "memory_pressure": ["unknown", "normal", "warning", "critical"],
            "thermal_state": ["unknown", "nominal", "fair", "serious", "critical"],
            "availability": ["available", "noMeeting", "multipleMeetings", "notJoined", "unavailable"],
            "platform": ["googleMeet", "zoom", "teams", "slackHuddle", "webex"],
            "source": ["app", "browser", "webkit"],
            "paste_detail": ["no_permission", "no_destination", "not_frontmost", "selection_changed", "clipboard_failed",
                             "key_failed", "no_text_field", "insertion_not_seen"]
        ]
        for (key, allowed) in categories {
            if let value = values[key]?.description, allowed.contains(value) { fields[key] = value }
        }
        let discardReasons: Set<String> = ["empty", "tooShort", "silent", "device_interruption"]
        if let value = values["reason"]?.description, discardReasons.contains(value) { fields["reason"] = value }
        sink.append(fields)
    }
}
