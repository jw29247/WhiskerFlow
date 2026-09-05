import Foundation

public enum AssistantRecordKind: String, Codable, CaseIterable, Sendable {
    case note
    case taskDraft
    case clientUpdateDraft
}

public enum AssistantSyncState: String, Codable, CaseIterable, Sendable {
    case pending
    case synced
    case failed
}

public struct PendingQuickCaptureDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var rawText: String
    public var kind: AssistantRecordKind
    public var createdAt: Date
    public var updatedAt: Date
    public var syncState: AssistantSyncState

    public init(id: UUID = UUID(), rawText: String, kind: AssistantRecordKind, createdAt: Date, updatedAt: Date, syncState: AssistantSyncState) {
        self.id = id
        self.rawText = rawText
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
    }
}

public struct ClientVocabularyProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var clientIdentifier: String
    public var vocabulary: Vocabulary
    public var createdAt: Date
    public var updatedAt: Date
    public var syncState: AssistantSyncState

    public init(id: String, clientIdentifier: String, vocabulary: Vocabulary, createdAt: Date, updatedAt: Date, syncState: AssistantSyncState) {
        self.id = id
        self.clientIdentifier = clientIdentifier
        self.vocabulary = vocabulary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
    }
}

public struct MeetingBookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var meetingIdentifier: String
    public var elapsedSeconds: TimeInterval
    public var createdAt: Date
    public var updatedAt: Date
    public var syncState: AssistantSyncState

    public init(id: UUID = UUID(), meetingIdentifier: String, elapsedSeconds: TimeInterval, createdAt: Date, updatedAt: Date, syncState: AssistantSyncState) {
        self.id = id
        self.meetingIdentifier = meetingIdentifier
        self.elapsedSeconds = elapsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
    }
}
