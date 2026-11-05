#if DEBUG
import AppKit
import Darwin
import WhiskerFlowCore

/// Local, explicit fixture evaluation. Never reads History, microphone audio,
/// preferences or network resources. Not compiled into release builds.
@MainActor
enum CleanupEvaluation {
    struct Fixture: Codable { let id: String; let input: String; let expected: String; let audioFile: String? }
    struct Row: Codable {
        let id: String
        let input: String
        let candidate: String
        let delivered: String
        let expected: String
        let seconds: Double
        let passed: Bool
    }
    struct Report: Codable {
        let model: String
        let loadSeconds: Double
        let footprintBefore: UInt64
        let footprintLoaded: UInt64
        let footprintReleased: UInt64
        let residentLoaded: UInt64
        let residentReleased: UInt64
        let warmIdleCPUPercent: Double
        let deadlineSeconds: Double
        let deadlineStopped: Bool
        let cancellationStopped: Bool
        let rows: [Row]
    }

    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--evaluate-cleanup"),
              CommandLine.arguments.count > index + 3 else { return false }
        let choice = CommandLine.arguments[index + 1]
        let input = URL(fileURLWithPath: CommandLine.arguments[index + 2])
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 3])
        guard choice == "gemma2" else { exit(2) }
        let model = CleanupModel.gemma2
        Task {
            do {
                let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: input))
                let worker = CleanupWorker()
                let before = footprint()
                let start = ProcessInfo.processInfo.systemUptime
                try await worker.prepare(model)
                let load = ProcessInfo.processInfo.systemUptime - start
                var rows: [Row] = []
                let transcription = TranscriptionService()
                for fixture in fixtures {
                    let input: String
                    if let audioFile = fixture.audioFile {
                        let outcome = try await transcription.transcribe(audioURL: URL(fileURLWithPath: audioFile),
                                                                       kind: .parakeetTDTv3, language: "en", allowAppleFallback: false)
                        input = outcome.result.text
                    } else {
                        input = fixture.input
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    let candidate = try await worker.generate(input, model: model, seconds: 8)
                    let delivered = TranscriptCleanup.accepted(candidate, original: input) ?? input
                    rows.append(Row(id: fixture.id, input: input, candidate: candidate, delivered: delivered,
                                    expected: fixture.expected, seconds: ProcessInfo.processInfo.systemUptime - start,
                                    passed: delivered == fixture.expected))
                }
                let loaded = footprint()
                let residentLoaded = residentMemory()
                let cpu = cpuSeconds()
                let idleStart = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let idleCPU = 100 * (cpuSeconds() - cpu) / (ProcessInfo.processInfo.systemUptime - idleStart)
                let deadlineStart = ProcessInfo.processInfo.systemUptime
                var deadlineStopped = false
                do { _ = try await worker.generate(fixtures[0].input, model: model, seconds: 0.000001) }
                catch { deadlineStopped = true }
                let deadlineSeconds = ProcessInfo.processInfo.systemUptime - deadlineStart
                let cancelled = Task { try await worker.generate(fixtures[0].input, model: model, seconds: 8) }
                cancelled.cancel()
                var cancellationStopped = false
                do { _ = try await cancelled.value }
                catch { cancellationStopped = true }
                await worker.unloadAndWait()
                try await Task.sleep(nanoseconds: 100_000_000)
                let released = footprint()
                let residentReleased = residentMemory()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let report = Report(model: model.name, loadSeconds: load, footprintBefore: before,
                                    footprintLoaded: loaded, footprintReleased: released,
                                    residentLoaded: residentLoaded, residentReleased: residentReleased, warmIdleCPUPercent: idleCPU,
                                    deadlineSeconds: deadlineSeconds, deadlineStopped: deadlineStopped,
                                    cancellationStopped: cancellationStopped, rows: rows)
                try encoder.encode(report).write(to: output, options: .atomic)
                exit(0)
            } catch {
                // Only explicit synthetic input runs here, but don't print model
                // paths or provider errors into the app's diagnostic pipeline.
                fputs("Cleanup evaluation failed\n", stderr)
                exit(1)
            }
        }
        return true
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
#endif
