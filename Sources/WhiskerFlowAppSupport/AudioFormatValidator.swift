import Foundation

public enum AudioFormatValidationError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case noInputChannels
}

public enum AudioFormatValidator {
    public static func validate(sampleRate: Double, channelCount: UInt32) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioFormatValidationError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0 else {
            throw AudioFormatValidationError.noInputChannels
        }
    }
}
