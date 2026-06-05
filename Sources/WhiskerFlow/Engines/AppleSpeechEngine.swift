import Foundation
import Speech
import WhiskerFlowCore

/// Built-in, zero-download fallback using the on-device Speech framework.
actor AppleSpeechEngine: TranscriptionEngine {
    nonisolated var kind: TranscriptionEngineKind { .appleSpeech }

    func isAvailable() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized || status == .notDetermined else { return false }
        return SFSpeechRecognizer()?.isAvailable ?? false
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard await requestAuthorization() else {
            throw TranscriptionError.engineUnavailable(.appleSpeech)
        }

        let locale = Locale(identifier: request.language.map(Self.localeIdentifier) ?? "en-US")
        guard
            let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
            recognizer.isAvailable
        else {
            throw TranscriptionError.engineUnavailable(.appleSpeech)
        }

        let speechRequest = SFSpeechURLRecognitionRequest(url: request.audioURL)
        speechRequest.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            speechRequest.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let guardOnce = ResumeGuard()
            // Capture `recognizer` so it outlives this scope until the task finishes.
            recognizer.recognitionTask(with: speechRequest) { result, error in
                _ = recognizer
                if let error {
                    if guardOnce.fire() {
                        continuation.resume(throwing: TranscriptionError.underlying(error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                if guardOnce.fire() {
                    continuation.resume(returning: TranscriptionResult(
                        text: text.plainTranscriptText,
                        language: request.language
                    ))
                }
            }
        }
    }

    /// Map a bare language code (e.g. "en") to a sensible recognizer locale.
    private static func localeIdentifier(_ code: String) -> String {
        if code.contains("-") { return code }
        switch code.lowercased() {
        case "en": return "en-US"
        default: return code
        }
    }
}
