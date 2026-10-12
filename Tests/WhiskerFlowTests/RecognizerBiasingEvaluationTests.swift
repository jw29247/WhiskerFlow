import AVFoundation
import FluidAudio
import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Opt-in before/after evaluation of dictionary biasing on each engine.
///
/// Clips are synthesised with `say` (no user audio is involved), plus silence,
/// low noise, a one-word clip and a clip with a long pause: the cases where a
/// Whisper prompt is most likely to be echoed or looped. Results go to
/// `WHISKERFLOW_BIAS_EVAL_OUTPUT` as JSON; see
/// docs/validation/2026-09-25-dictionary-biasing.md for the write-up.
final class RecognizerBiasingEvaluationTests: XCTestCase {
    struct Clip {
        let name: String
        let reference: String
        let url: URL
    }

    /// Dictionary words plus the shared library's written terms, the way the
    /// app builds the hint list (`DictionaryBiasing.terms`).
    static let terms = DictionaryBiasing.terms(
        personal: ["Siobhan", "Niamh", "WhiskerFlow", "Kubernetes", "Superlog", "Figma"].map { .word($0) },
        readOnly: ["BPerfect", "Cleens", "Comfybedss", "Firma Stella", "Manukora", "Nuve", "Otty", "Travlfi",
                   "Vivamn", "Water2"].map { VocabularyRule(find: $0.lowercased(), replaceWith: $0) })

    static let spoken: [(name: String, voice: String, text: String)] = [
        ("clients-1", "Daniel", "Send the Manukora and Otty reports to Siobhan before Friday."),
        ("clients-2", "Samantha", "The Travlfi launch moved, so Niamh will update the Firma Stella brief."),
        ("clients-3", "Daniel", "Comfybedss and Cleens both asked about the BPerfect bundle."),
        ("clients-4", "Samantha", "Vivamn wants the Nuve landing page in Figma by Tuesday."),
        ("tech", "Daniel", "Deploy WhiskerFlow to Kubernetes and log it in Superlog."),
        ("control-prose", "Samantha", "The weather was lovely so we walked into town and bought some bread."),
        ("control-short", "Daniel", "Yes.")
    ]

    private var outputURL: URL!
    private var folder: URL!
    private var clips: [Clip] = []
    private var rows: [[String: Any]] = []

    override func setUp() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHISKERFLOW_BIAS_EVAL_OUTPUT"] else {
            throw XCTSkip("Set WHISKERFLOW_BIAS_EVAL_OUTPUT to run the biasing evaluation")
        }
        outputURL = URL(fileURLWithPath: output)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wf-bias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in Self.spoken {
            let url = folder.appendingPathComponent("\(item.name).wav")
            try say(item.text, voice: item.voice, to: url)
            clips.append(Clip(name: item.name, reference: item.text, url: url))
        }
        let sampleRate = 16_000
        clips.append(Clip(name: "silence-5s", reference: "", url: try write([Float](repeating: 0, count: 5 * sampleRate), name: "silence")))
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(5 * sampleRate)).map { _ in Float.random(in: -0.004...0.004, using: &generator) }
        clips.append(Clip(name: "noise-5s", reference: "", url: try write(noise, name: "noise")))
        let first = folder.appendingPathComponent("pause-a.wav"), second = folder.appendingPathComponent("pause-b.wav")
        try say("I will call you back later.", voice: "Samantha", to: first)
        try say("Thanks, bye.", voice: "Samantha", to: second)
        let converter = AudioConverter()
        let joined = try converter.resampleAudioFile(first) + [Float](repeating: 0, count: 4 * sampleRate)
            + converter.resampleAudioFile(second)
        clips.append(Clip(name: "long-pause", reference: "I will call you back later. Thanks, bye.",
                          url: try write(joined, name: "pause")))
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testParakeetVocabularyBoosting() async throws {
        let engine = ParakeetTDTv3Engine()
        try await engine.prepare()
        await engine.booster.prepare()
        for _ in 0..<600 where await !(engine.booster.isReady) { try await Task.sleep(for: .milliseconds(500)) }
        let ready = await engine.booster.isReady
        XCTAssertTrue(ready, "CTC boosting model failed to load")
        for biased in [false, true] {
            let hints = RecognizerHints(terms: biased ? Self.terms : [], parakeet: true)
            for clip in clips {
                let samples = try AudioConverter().resampleAudioFile(clip.url)
                try await record(engine: "parakeet-tdt-v3", mode: "capture", biased: biased, clip: clip) {
                    try await engine.transcribe(samples: samples, language: "en", hints: hints).text
                }
            }
        }
    }

    /// Needs Speech Recognition permission for the test runner; run on its own.
    func testAppleSpeechContextualStrings() async throws {
        guard ProcessInfo.processInfo.environment["WHISKERFLOW_BIAS_EVAL_APPLE"] == "1" else {
            throw XCTSkip("Set WHISKERFLOW_BIAS_EVAL_APPLE=1 (requires Speech Recognition permission)")
        }
        let engine = AppleSpeechEngine()
        for biased in [false, true] {
            let hints = RecognizerHints(terms: biased ? Self.terms : [], appleSpeech: true)
            for clip in clips {
                try await record(engine: "apple-speech", mode: "file", biased: biased, clip: clip) {
                    try await engine.transcribe(TranscriptionRequest(audioURL: clip.url, language: "en", hints: hints)).text
                }
            }
        }
    }

    // MARK: - Measurement

    private func record(engine: String, mode: String, biased: Bool, clip: Clip,
                        _ run: () async throws -> String) async throws {
        let start = ContinuousClock.now
        var text = ""
        var error: String?
        do { text = try await run() } catch let caught { error = caught.localizedDescription }
        let elapsed = start.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        let expected = Self.terms.filter { clip.reference.localizedCaseInsensitiveContains($0) }
        let hits = expected.filter { text.contains($0) }
        // A hint term in the output that the speaker never said: an echoed prompt.
        let leaked = Self.terms.filter { !clip.reference.localizedCaseInsensitiveContains($0) && text.localizedCaseInsensitiveContains($0) }
        let row: [String: Any] = [
            "engine": engine, "mode": mode, "biased": biased, "clip": clip.name, "reference": clip.reference,
            "text": text, "error": error ?? NSNull(), "ms": Int(ms),
            "expectedTerms": expected.count, "termHits": hits.count, "leakedTerms": leaked,
            "maxRepeatedTrigram": Self.maxRepeatedTrigram(text),
            "wordRatio": clip.reference.isEmpty ? NSNull() : Double(Self.words(text).count) / Double(max(1, Self.words(clip.reference).count))
        ]
        rows.append(row)
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outputURL.deletingPathExtension().path + "-\(engine.split(separator: "-")[0]).json"),
                   options: .atomic)
        print("BIAS \(engine) \(mode) biased=\(biased) \(clip.name) \(Int(ms))ms hits=\(hits.count)/\(expected.count) leaked=\(leaked) :: \(text)\(error.map { " [\($0)]" } ?? "")")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func maxRepeatedTrigram(_ text: String) -> Int {
        let tokens = words(text)
        guard tokens.count >= 3 else { return 0 }
        var counts: [String: Int] = [:]
        for index in 0...(tokens.count - 3) { counts[tokens[index..<(index + 3)].joined(separator: " "), default: 0] += 1 }
        return counts.values.max() ?? 0
    }

    // MARK: - Audio

    private func say(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "say failed for \(text)")
    }

    private func write(_ samples: [Float], name: String) throws -> URL {
        let url = folder.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }
}
