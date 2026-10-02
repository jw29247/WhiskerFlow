@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Apple's on-device dictation model (`DictationTranscriber`, macOS 26), for
/// languages Parakeet doesn't speak: Hindi, Arabic, Japanese, Chinese and
/// others. Audio never leaves the Mac, and no Speech Recognition permission
/// is needed. Each language's model downloads once (about 20 s).
@available(macOS 26.0, *)
actor AppleDictationEngine {
    enum ModelState: Equatable, Sendable { case installed, needsDownload, unsupported }

    /// Languages written without spaces between results.
    private static let unspacedLanguages: Set<String> = ["ja", "zh", "yue", "th"]

    static func modelState(locale identifier: String) async -> ModelState {
        let transcriber = DictationTranscriber(locale: Locale(identifier: identifier), preset: .shortDictation)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .supported, .downloading: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads the language's model if it isn't on the Mac yet.
    func prepare(locale identifier: String) async throws {
        let transcriber = DictationTranscriber(locale: Locale(identifier: identifier), preset: .shortDictation)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return
        case .unsupported: throw TranscriptionError.engineUnavailable(.appleDictation)
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
    }

    func transcribe(_ request: TranscriptionRequest, locale identifier: String) async throws -> TranscriptionResult {
        try await prepare(locale: identifier)
        let audioURL = request.audioURL
        let timeout = DecodeTimeoutPolicy.appleSpeechTimeout(forAudioSeconds: Self.audioSeconds(at: audioURL) ?? 0)
        let unspaced = Self.unspacedLanguages.contains(String(identifier.prefix { $0 != "-" }))
        do {
            return try await withTimeout(seconds: timeout) {
                let transcriber = DictationTranscriber(locale: Locale(identifier: identifier), preset: .shortDictation)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let file = try AVAudioFile(forReading: audioURL)
                async let collected = transcriber.results.reduce(into: [TranscriptionSegment]()) { segments, result in
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    segments.append(TranscriptionSegment(text: text, start: result.range.start.seconds,
                                                         end: result.range.end.seconds))
                }
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let segments = try await collected
                let text = segments.map(\.text).joined(separator: unspaced ? "" : " ")
                guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
                return TranscriptionResult(text: text.plainTranscriptText, segments: segments,
                                           language: identifier, duration: file.duration)
            }
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.underlying(error.localizedDescription)
        }
    }

    private static func audioSeconds(at url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.duration
    }
}

private extension AVAudioFile {
    var duration: Double? {
        let rate = fileFormat.sampleRate
        return rate > 0 ? Double(length) / rate : nil
    }
}
