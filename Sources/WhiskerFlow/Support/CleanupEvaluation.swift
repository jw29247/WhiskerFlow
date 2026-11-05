#if DEBUG
import AppKit
import Darwin
import WhiskerFlowCore

/// Local, explicit fixture evaluation. Never reads History, microphone audio,
/// preferences or network resources. Not compiled into release builds.
@MainActor
enum CleanupEvaluation {
    struct Fixture: Codable { let id: String; let input: String; let expected: String; let audioFile: String?; let rules: [VocabularyRule]?; let prompt: String? }
    struct Row: Codable {
        let id: String
        let input: String
        let candidate: String
        let delivered: String
        let expected: String
        let seconds: Double
        let passed: Bool
        let failure: String?
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
        let reloadSeconds: Double?
        let rows: [Row]
    }

    static func runIfRequested() -> Bool {
        if runLearningIfRequested() { return true }
        guard let index = CommandLine.arguments.firstIndex(of: "--evaluate-cleanup"),
              CommandLine.arguments.count > index + 3 else { return false }
        let choice = CommandLine.arguments[index + 1]
        let input = URL(fileURLWithPath: CommandLine.arguments[index + 2])
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 3])
        guard let model = CleanupModel(rawValue: choice) else { exit(2) }
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
                    let vocabulary = Vocabulary(rules: fixture.rules ?? [])
                    let candidate: String
                    let delivered: String
                    let failure: String?
                    do {
                        if let prompt = fixture.prompt {
                            candidate = try await worker.generatePrompt(prompt, model: model, tokenLimit: 500, seconds: 3)
                            delivered = TranscriptCleanup.accepted(candidate, original: input, vocabulary: vocabulary) ?? input
                            failure = nil
                        } else {
                            let attempt = try await worker.cleanTranscript(input, model: model, seconds: input.count > 800 ? 8 : 3, vocabulary: vocabulary)
                            candidate = attempt.candidate
                            delivered = attempt.text
                            failure = attempt.incomplete ? "incomplete" : nil
                        }
                    } catch {
                        candidate = ""
                        delivered = input
                        failure = String(describing: type(of: error))
                    }
                    rows.append(Row(id: fixture.id, input: input, candidate: candidate, delivered: delivered,
                                    expected: fixture.expected, seconds: ProcessInfo.processInfo.systemUptime - start,
                                    passed: delivered == fixture.expected, failure: failure))
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
                let reloadStart = ProcessInfo.processInfo.systemUptime
                let reloadSeconds: Double?
                do {
                    try await worker.prepare(model)
                    reloadSeconds = ProcessInfo.processInfo.systemUptime - reloadStart
                } catch {
                    // Preserve completed rows if current memory pressure prevents
                    // this optional second load. Never silently erase a run.
                    reloadSeconds = nil
                }
                await worker.unloadAndWait()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let report = Report(model: model.name, loadSeconds: load, footprintBefore: before,
                                    footprintLoaded: loaded, footprintReleased: released,
                                    residentLoaded: residentLoaded, residentReleased: residentReleased, warmIdleCPUPercent: idleCPU,
                                    deadlineSeconds: deadlineSeconds, deadlineStopped: deadlineStopped,
                                    cancellationStopped: cancellationStopped, reloadSeconds: reloadSeconds, rows: rows)
                try encoder.encode(report).write(to: output, options: .atomic)
                exit(0)
            } catch let failure as CleanupFailure {
                fputs("Cleanup evaluation failed: \(failure)\n", stderr)
                exit(1)
            } catch {
                // Only explicit synthetic input runs here, but don't print model
                // paths or provider errors into the app's diagnostic pipeline.
                fputs("Cleanup evaluation failed\n", stderr)
                exit(1)
            }
        }
        return true
    }

    struct LearningFixture: Codable {
        let id: String
        let original: String
        let edited: String
        let expected: [VocabularyCorrection]
    }
    struct LearningRow: Codable {
        let id: String
        let approved: [VocabularyCorrection]
        let expected: [VocabularyCorrection]
        let passed: Bool
        let seconds: Double
    }

    private static func runLearningIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--evaluate-correction-learning"),
              CommandLine.arguments.count > index + 2 else { return false }
        let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
        let model = CommandLine.arguments.count > index + 3 ? CleanupModel(rawValue: CommandLine.arguments[index + 3]) ?? .gemma4E2B : .gemma4E2B
        Task {
            do {
                let fixtures = try JSONDecoder().decode([LearningFixture].self, from: Data(contentsOf: input))
                let service = CleanupService()
                service.configure(model: model, enabled: true)
                var rows: [LearningRow] = []
                for fixture in fixtures {
                    let started = ProcessInfo.processInfo.systemUptime
                    let approved = try await service.assess(CorrectionEdit(original: fixture.original, edited: fixture.edited))
                    rows.append(LearningRow(id: fixture.id, approved: approved, expected: fixture.expected,
                                            passed: Set(approved) == Set(fixture.expected),
                                            seconds: ProcessInfo.processInfo.systemUptime - started))
                }
                await service.shutdown()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: output, options: .atomic)
                exit(0)
            } catch {
                fputs("Correction learning evaluation failed\n", stderr)
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
