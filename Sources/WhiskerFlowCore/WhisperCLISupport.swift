import Foundation

/// Configuration for the advanced "bring your own openai-whisper CLI" engine.
public struct WhisperConfiguration: Hashable, Sendable {
    public var command: String
    public var argumentsTemplate: String

    public init(command: String, argumentsTemplate: String) {
        self.command = command
        self.argumentsTemplate = argumentsTemplate
    }

    /// Tokenized arguments with `{audio}` / `{output}` placeholders substituted.
    public func resolvedArguments(audioPath: String, outputPath: String) throws -> [String] {
        try ShellArguments.split(argumentsTemplate).map { argument in
            argument
                .replacingOccurrences(of: "{audio}", with: audioPath)
                .replacingOccurrences(of: "{output}", with: outputPath)
        }
    }
}

public enum WhisperCLIError: LocalizedError, Equatable {
    case commandNotFound(String)
    case failed(String)
    case emptyTranscript
    case unterminatedQuote

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "Whisper command not found: \(command). Set it to /opt/homebrew/bin/whisper."
        case .failed(let message):
            return "Whisper failed: \(message)"
        case .emptyTranscript:
            return "Whisper completed without producing transcript text."
        case .unterminatedQuote:
            return "Whisper arguments contain an unterminated quote."
        }
    }
}

/// Minimal POSIX-ish argument splitter: honors single/double quotes and backslash escapes.
public enum ShellArguments {
    public static func split(_ string: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escapeNext = false
        var sawToken = false

        for character in string {
            if escapeNext {
                current.append(character)
                escapeNext = false
                continue
            }

            if character == "\\" {
                escapeNext = true
                sawToken = true
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
                sawToken = true
            } else if character.isWhitespace {
                if sawToken {
                    arguments.append(current)
                    current = ""
                    sawToken = false
                }
            } else {
                current.append(character)
                sawToken = true
            }
        }

        if quote != nil {
            throw WhisperCLIError.unterminatedQuote
        }

        if sawToken {
            arguments.append(current)
        }

        return arguments
    }
}
