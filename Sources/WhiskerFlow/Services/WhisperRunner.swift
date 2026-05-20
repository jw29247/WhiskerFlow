import Foundation

struct WhisperConfiguration: Hashable {
    var command: String
    var argumentsTemplate: String
}

struct WhisperRunner {
    func transcribe(audioURL: URL, configuration: WhisperConfiguration) async throws -> String {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let arguments = try ShellArguments.split(configuration.argumentsTemplate).map { argument in
            argument
                .replacingOccurrences(of: "{audio}", with: audioURL.path)
                .replacingOccurrences(of: "{output}", with: outputDirectory.path)
        }

        let result = try await run(command: configuration.command, arguments: arguments)
        guard result.exitCode == 0 else {
            throw WhisperError.failed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        if let textURL = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "txt" }) {
            let text = try String(contentsOf: textURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            throw WhisperError.emptyTranscript
        }
        return stdout
    }

    private func run(command: String, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let resolvedCommand = resolveCommand(command)

            guard resolvedCommand.contains("/"), FileManager.default.isExecutableFile(atPath: resolvedCommand) else {
                throw WhisperError.commandNotFound(command)
            }

            process.executableURL = URL(fileURLWithPath: resolvedCommand)
            process.arguments = arguments
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path
            ]
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

private func resolveCommand(_ command: String) -> String {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedCommand.contains("/") {
        return trimmedCommand
    }

    let paths = [
        "/opt/homebrew/bin/\(trimmedCommand)",
        "/usr/local/bin/\(trimmedCommand)"
    ]

    return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? trimmedCommand
}

private struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum WhisperError: LocalizedError {
    case commandNotFound(String)
    case failed(String)
    case emptyTranscript
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            "Whisper command not found: \(command). Set it to /opt/homebrew/bin/whisper."
        case .failed(let message):
            "Whisper failed: \(message)"
        case .emptyTranscript:
            "Whisper completed without producing transcript text."
        case .unterminatedQuote:
            "Whisper arguments contain an unterminated quote."
        }
    }
}

enum ShellArguments {
    static func split(_ string: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escapeNext = false

        for character in string {
            if escapeNext {
                current.append(character)
                escapeNext = false
                continue
            }

            if character == "\\" {
                escapeNext = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if quote != nil {
            throw WhisperError.unterminatedQuote
        }

        if !current.isEmpty {
            arguments.append(current)
        }

        return arguments
    }
}
