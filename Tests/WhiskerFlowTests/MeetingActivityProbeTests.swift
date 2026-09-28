import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Opt-in, local-only: classifies each second of a retained recording the way
/// the live coach does and prints counts and level percentiles only. No audio,
/// text or names leave the test, and the recording is only read.
/// `WHISKERFLOW_ACTIVITY_PROBE_SESSION=<uuid> [WHISKERFLOW_ACTIVITY_PROBE_MIN_MS=…] swift test --filter MeetingActivityProbeTests`
final class MeetingActivityProbeTests: XCTestCase {
    func testClassifyRetainedRecording() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WHISKERFLOW_ACTIVITY_PROBE_SESSION"], let id = UUID(uuidString: raw) else {
            throw XCTSkip("Opt-in activity probe")
        }
        let root = StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingRecordings")
        let store = EncryptedMeetingChunkStore(rootURL: root, keyProvider: KeychainMeetingChunkKeyProvider())
        let manifest = try store.loadManifest(sessionID: id)
        let minMs = env["WHISKERFLOW_ACTIVITY_PROBE_MIN_MS"].flatMap(Int64.init) ?? 0
        func samples(_ track: MeetingAudioTrack) throws -> [Float] {
            try manifest.chunks.filter { $0.track == track && $0.startMs >= minMs }.sorted { $0.sequence < $1.sequence }
                .flatMap { chunk -> [Float] in
                    let data = try store.readChunk(sessionID: id, descriptor: chunk)
                    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
        }
        let mic = try samples(.microphone), system = try samples(.system)
        let seconds = min(mic.count, system.count) / 16_000
        func rms(_ s: ArraySlice<Float>) -> Double { s.isEmpty ? 0 : sqrt(s.reduce(0.0) { $0 + Double($1 * $1) } / Double(s.count)) }
        // Live rule: a second is active when any 100 ms buffer reaches RMS 0.015.
        func active(_ s: [Float], _ second: Int) -> Bool {
            (0..<10).contains { b in rms(s[(second * 16_000 + b * 1_600)..<(second * 16_000 + (b + 1) * 1_600)]) >= 0.015 }
        }
        var states: [String: Int] = [:]
        var micLevels: [Double] = [], systemLevels: [Double] = []
        for second in 0..<seconds {
            let m = active(mic, second), s = active(system, second)
            states[m && s ? "both" : m ? "you" : s ? "others" : "silence", default: 0] += 1
            micLevels.append(rms(mic[(second * 16_000)..<((second + 1) * 16_000)]))
            systemLevels.append(rms(system[(second * 16_000)..<((second + 1) * 16_000)]))
        }
        // The adaptive rule, second by second, and the final transcript's labels
        // (You versus everyone else) as a reference when they exist.
        var classifier = MeetingSpeakerActivityClassifier()
        var adaptive: [String: Int] = [:]
        var adaptiveYou: [Bool] = []
        for second in 0..<seconds {
            let range = (second * 16_000)..<((second + 1) * 16_000)
            let result = classifier.classify(microphone: Array(mic[range]), system: Array(system[range]))
            let you = result.you == true, others = result.others == true
            adaptive[you && others ? "both" : you ? "you" : others ? "others" : "silence", default: 0] += 1
            adaptiveYou.append(you)
        }
        print("ACTIVITY_PROBE_ADAPTIVE: states=\(adaptive) noise_floor_rms=\(classifier.noiseFloorMeanSquare.map { String(format: "%.4f", sqrt($0)) } ?? "-") bleed_gain=\(classifier.bleedGain.map { String(format: "%.3f", $0) } ?? "-")")
        let libraryRoot = StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingLibrary")
        if let entry = try? EncryptedMeetingLibraryStore(rootURL: libraryRoot, keyProvider: KeychainMeetingChunkKeyProvider())
            .loadAll().entries.first(where: { $0.sessionID == id }), !entry.turns.isEmpty {
            var reference: [Bool?] = Array(repeating: nil, count: seconds)
            for turn in entry.turns {
                let start = Int((turn.startMs - minMs) / 1_000), end = Int((turn.endMs - minMs) / 1_000)
                guard end > 0, start < seconds else { continue }
                for index in max(0, start)..<min(seconds, max(start + 1, end)) {
                    reference[index] = (reference[index] ?? false) || turn.speaker.resolution == .selfSpeaker
                }
            }
            func score(_ you: (Int) -> Bool, _ name: String) {
                var tp = 0, fp = 0, fn = 0, tn = 0
                for index in 0..<seconds { guard let truth = reference[index] else { continue }
                    switch (you(index), truth) { case (true, true): tp += 1; case (true, false): fp += 1; case (false, true): fn += 1; case (false, false): tn += 1 }
                }
                let precision = tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp), recall = tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn)
                print("ACTIVITY_PROBE_SCORE: \(name) you_seconds_true=\(tp + fn) predicted=\(tp + fp) precision=\(String(format: "%.2f", precision)) recall=\(String(format: "%.2f", recall)) others_seconds_called_you=\(fp) of \(fp + tn)")
            }
            score({ active(mic, $0) }, "fixed_threshold")
            score({ adaptiveYou[$0] }, "adaptive_default")
            // A small grid, to tune against the transcript.
            for margin in [4.0, 8.0, 16.0] {
                for percentile in [0.25, 0.5] {
                    for before in [2, 4] {
                        var candidate = MeetingSpeakerActivityClassifier(bleedMargin: margin, bleedPercentile: percentile, leakFramesBefore: before, leakFramesAfter: 1)
                        var youByCandidate: [Bool] = []
                        for second in 0..<seconds {
                            let range = (second * 16_000)..<((second + 1) * 16_000)
                            youByCandidate.append(candidate.classify(microphone: Array(mic[range]), system: Array(system[range])).you == true)
                        }
                        score({ youByCandidate[$0] }, "margin=\(Int(margin)) pct=\(percentile) before=\(before)")
                    }
                }
            }
            let refYou = reference.compactMap { $0 }.filter { $0 }.count, refAll = reference.compactMap { $0 }.count
            print("ACTIVITY_PROBE_REFERENCE: transcript_you_share=\(refAll == 0 ? "-" : String(format: "%.2f", Double(refYou) / Double(refAll))) labelled_seconds=\(refAll)")
        } else {
            let entry = try? EncryptedMeetingLibraryStore(rootURL: libraryRoot, keyProvider: KeychainMeetingChunkKeyProvider())
                .loadAll().entries.first(where: { $0.sessionID == id })
            print("ACTIVITY_PROBE_REFERENCE: no transcript yet; status=\(entry?.status.rawValue ?? "-") detail=\(entry?.statusDetail ?? "-")")
        }
        func pct(_ v: [Double], _ p: Double) -> String { v.isEmpty ? "-" : String(format: "%.4f", v.sorted()[min(v.count - 1, Int(Double(v.count) * p))]) }
        print("ACTIVITY_PROBE: seconds=\(seconds) states=\(states)")
        print("ACTIVITY_PROBE: mic_rms p50=\(pct(micLevels, 0.5)) p90=\(pct(micLevels, 0.9)) | system_rms p50=\(pct(systemLevels, 0.5)) p90=\(pct(systemLevels, 0.9)) max=\(pct(systemLevels, 0.999))")
    }
}
