public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case standard
    case conversational
    case polished
    case literal
}

public struct WritingProfile: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var style: WritingStyle

    public init(bundleIdentifier: String, style: WritingStyle) {
        self.bundleIdentifier = bundleIdentifier
        self.style = style
    }
}
