public enum AssistantInferenceDenialReason: String, Codable, Equatable, Sendable {
    case activeDictation
    case activeMeetingRecording
    case simultaneousASR
    case modelUnavailable
    case excessiveInput
    case memoryPressure
}

public enum AssistantInferenceDecision: Equatable, Sendable {
    case allowedLocal
    case denied(AssistantInferenceDenialReason)
}

public struct AssistantInferenceContext: Equatable, Sendable {
    public var isDictating: Bool
    public var isMeetingRecording: Bool
    public var isASRRunning: Bool
    public var isModelAvailable: Bool
    public var inputByteCount: Int
    public var maximumInputByteCount: Int
    public var isMemoryPressureHigh: Bool

    public init(isDictating: Bool = false, isMeetingRecording: Bool = false, isASRRunning: Bool = false, isModelAvailable: Bool = true, inputByteCount: Int = 0, maximumInputByteCount: Int = 32_768, isMemoryPressureHigh: Bool = false) {
        self.isDictating = isDictating
        self.isMeetingRecording = isMeetingRecording
        self.isASRRunning = isASRRunning
        self.isModelAvailable = isModelAvailable
        self.inputByteCount = inputByteCount
        self.maximumInputByteCount = maximumInputByteCount
        self.isMemoryPressureHigh = isMemoryPressureHigh
    }
}

public enum AssistantInferencePolicy {
    public static func evaluate(_ context: AssistantInferenceContext) -> AssistantInferenceDecision {
        if context.isDictating { return .denied(.activeDictation) }
        if context.isMeetingRecording { return .denied(.activeMeetingRecording) }
        if context.isASRRunning { return .denied(.simultaneousASR) }
        if !context.isModelAvailable { return .denied(.modelUnavailable) }
        if context.inputByteCount < 0 || context.maximumInputByteCount < 0 || context.inputByteCount > context.maximumInputByteCount { return .denied(.excessiveInput) }
        if context.isMemoryPressureHigh { return .denied(.memoryPressure) }
        return .allowedLocal
    }
}
