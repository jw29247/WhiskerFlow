import Foundation
import WhiskerFlowCore

/// Advanced engine: shells out to a user-provided `openai-whisper` CLI.
/// Fixes the original deadlock (concurrent pipe drain) and adds a timeout.
struct WhisperCLIEngine: TranscriptionEngine {
    let configuration: WhisperConfiguration
    var timeout: TimeInterval = 180

    nonisolated var kind: TranscriptionEngineKind { .whisperCLI }

    func isAvailable() async -> Bool {
        guard let resolved = Self.resolveCommand(configuration.command) else { return false }
        return FileManager.default.isExecutableFile(atPath: resolved)
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let arguments = try configuration.resolvedArguments(
            audioPath: request.audioURL.path,
            outputPath: outputDirectory.path
        )

        guard
            let resolved = Self.resolveCommand(configuration.command),
            FileManager.default.isExecutableFile(atPath: resolved)
        else {
            throw WhisperCLIError.commandNotFound(configuration.command)
        }

        let output = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: resolved),
            arguments: arguments,
            environment: [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path
            ],
            timeout: timeout
        )

        guard output.exitCode == 0 else {
            throw WhisperCLIError.failed(output.stderr.isEmpty ? output.stdout : output.stderr)
        }

        var text = (try? Self.readTranscript(in: outputDirectory)) ?? ""
        if text.isEmpty {
            text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw WhisperCLIError.emptyTranscript }

        return TranscriptionResult(text: text.plainTranscriptText, language: request.language)
    }

    private static func readTranscript(in directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let txt = files.first(where: { $0.pathExtension == "txt" }) else { return "" }
        return try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") { return trimmed }

        let candidates = ["/opt/homebrew/bin/\(trimmed)", "/usr/local/bin/\(trimmed)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
