import Foundation
import Darwin
import Logging

/// Temporary diagnostic sampler. Invoked only after a detected main-thread stall,
/// at most once per five minutes. Persists symbol names, never raw sample reports.
final class StallStackCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCapture: TimeInterval = -.infinity
    private let directory: URL
    private let mainThreadID = StallStackCapture.currentMainThreadID()
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WhiskerFlow/stacks")) {
        self.directory = directory
    }
    func captureIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard now - lastCapture >= 300 else { lock.unlock(); return }
        lastCapture = now
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let id = UUID()
            let started = ProcessInfo.processInfo.systemUptime
            logger.info("Stall stack capture started", metadata: ["event": "stack_capture_started", "capture_id": "\(id)"])
            var shape: [String: Logger.MetadataValue] = [:]
            do {
                let report = try Self.sample(pid: ProcessInfo.processInfo.processIdentifier)
                shape = Self.reportShape(report).mapValues { .string(String($0)) }
                let frames = Self.mainThreadFrames(report, mainThreadID: mainThreadID)
                guard !frames.isEmpty else { throw CaptureError.noFrames }
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let row: [String: Any] = ["capture_id": id.uuidString,
                    "timestamp": Date().timeIntervalSince1970,
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "build": Bundle.main.object(forInfoDictionaryKey: "WhiskerFlowBuildRevision") as? String ?? "development",
                    "main_thread_frames": frames,
                    "frame_retention_policy": "first16_last48_when_over64"]
                let data = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                for index in stride(from: 3, through: 1, by: -1) {
                    let file = directory.appendingPathComponent("stall-\(index).json")
                    if fm.fileExists(atPath: file.path) {
                        if index == 3 { try fm.removeItem(at: file) }
                        else { try fm.moveItem(at: file, to: directory.appendingPathComponent("stall-\(index + 1).json")) }
                    }
                }
                let file = directory.appendingPathComponent("stall-1.json")
                try data.write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                logger.info("Stall stack captured", metadata: ["event": "stack_captured", "capture_id": "\(id)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - started) * 1000)"])
            } catch {
                let reason = (error as? CaptureError)?.rawValue ?? "write_failed"
                shape.merge(["event": "stack_capture_failed", "capture_id": "\(id)", "capture_failure": "\(reason)", "elapsed_ms": "\((ProcessInfo.processInfo.systemUptime - started) * 1000)"]) { _, new in new }
                logger.warning("Stall stack capture unavailable", metadata: shape)
            }
        }
    }

    enum CaptureError: String, Error {
        case noFrames = "no_frames", launchFailed = "launch_failed"
        case terminated, nonzeroExit = "nonzero_exit"
    }
    static func sample(pid: Int32) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), "1", "10", "-file", "/dev/stdout"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CaptureError.launchFailed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        // Report completion exceeded eight seconds during observed memory pressure.
        // Sampling remains one second; only bounded report completion gets longer.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        var report = Data()
        // Drain continuously to avoid pipe backpressure; cap retained bytes.
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            if report.count < 1_000_000 { report.append(data.prefix(1_000_000 - report.count)) }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw CaptureError.terminated }
        guard process.terminationStatus == 0 else { throw CaptureError.nonzeroExit }
        return String(decoding: report, as: UTF8.self)
    }

    /// Only structural counters leave the in-memory report, never raw headers.
    static func reportShape(_ report: String) -> [String: Int] {
        let lines = report.split(separator: "\n")
        let headers = lines.filter { $0.contains("Thread_") && !$0.contains("(in ") }
        return ["sample_report_bytes": report.utf8.count,
                "sample_thread_headers": headers.count,
                "sample_main_headers": headers.filter { $0.contains("com.apple.main-thread") }.count,
                "sample_symbol_lines": lines.filter { $0.contains("(in ") }.count]
    }

    /// Capture identity during main-thread startup, before any stall occurs.
    static func currentMainThreadID() -> UInt64? {
        guard Thread.isMainThread else { return nil }
        var id: UInt64 = 0
        guard pthread_threadid_np(nil, &id) == 0 else { return nil }
        return id
    }

    static func mainThreadFrames(_ report: String, mainThreadID: UInt64? = nil) -> [String] {
        var inMain = false
        var frames: [String] = []
        for raw in report.split(separator: "\n") {
            let line = String(raw)
            if line.contains("Thread_"), !line.contains("(in ") {
                if inMain { break }
                let idMatch = mainThreadID.map { id in
                    line.range(of: "Thread_\(id)(?![0-9])", options: .regularExpression) != nil
                } ?? false
                inMain = idMatch || line.contains("com.apple.main-thread")
                continue
            }
            guard inMain else { continue }
            if let range = line.range(of: #"^\s*[+!:| ]*\d+ .*?\(in [^)]*\)"#, options: .regularExpression) {
                frames.append(String(line[range]).trimmingCharacters(in: .whitespaces))
                // Keep root context and the end of long call trees. A prefix-only
                // cap discarded deeper calls in real SwiftUI scene/menu stalls.
                // This is a bounded excerpt, not a contiguous complete stack.
                if frames.count > 64 { frames.remove(at: 16) }
            }
        }
        return frames
    }
}
