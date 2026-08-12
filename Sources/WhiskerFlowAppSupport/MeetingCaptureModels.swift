import Foundation

public enum MeetingAudioTrack: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case system
    case mixed
}

public enum MeetingLocalRecordingState: String, Codable, Sendable {
    case recording
    case uploading
    case awaitingTranscription
    case completed
    case failed
}

public enum MeetingChunkUploadState: String, Codable, Sendable {
    case pending
    case uploaded
}

public enum MeetingCoverageStatus: String, Codable, CaseIterable, Sendable {
    case covered
    case partial
    case recordedPendingUpload = "recorded_pending_upload"
    case recordedPendingTranscription = "recorded_pending_transcription"
    case uncovered
    case failed
}

public struct MeetingRecordingChunkDescriptor: Codable, Equatable, Sendable {
    public let track: MeetingAudioTrack
    public let sequence: Int
    public let startMs: Int64
    public let endMs: Int64
    public let byteSize: Int
    public let checksum: String
    public let relativePath: String
    public var uploadState: MeetingChunkUploadState

    public init(
        track: MeetingAudioTrack,
        sequence: Int,
        startMs: Int64,
        endMs: Int64,
        byteSize: Int,
        checksum: String,
        relativePath: String,
        uploadState: MeetingChunkUploadState = .pending
    ) {
        self.track = track
        self.sequence = sequence
        self.startMs = startMs
        self.endMs = endMs
        self.byteSize = byteSize
        self.checksum = checksum
        self.relativePath = relativePath
        self.uploadState = uploadState
    }

    private enum CodingKeys: String, CodingKey {
        case track, sequence, startMs, endMs, byteSize, checksum, relativePath, uploadState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.track = try container.decode(MeetingAudioTrack.self, forKey: .track)
        self.sequence = try container.decode(Int.self, forKey: .sequence)
        self.startMs = try container.decode(Int64.self, forKey: .startMs)
        self.endMs = try container.decode(Int64.self, forKey: .endMs)
        self.byteSize = try container.decode(Int.self, forKey: .byteSize)
        self.checksum = try container.decode(String.self, forKey: .checksum)
        self.relativePath = try container.decode(String.self, forKey: .relativePath)
        self.uploadState = try container.decodeIfPresent(MeetingChunkUploadState.self, forKey: .uploadState) ?? .pending
    }
}

public struct MeetingRecordingSessionManifest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let meetingID: String?
    public let createdAt: Date
    public var expectedChunkCounts: [MeetingAudioTrack: Int]
    public let title: String?
    public let calendarEventID: String?
    public let occurredAtMs: Int64?
    public var atlasMeetingID: String?
    public var atlasArtifactID: String?
    public var state: MeetingLocalRecordingState
    public var durationMs: Int64?
    public var sourceGapDetected: Bool
    public var chunks: [MeetingRecordingChunkDescriptor]

    public init(
        sessionID: UUID,
        meetingID: String?,
        createdAt: Date = Date(),
        expectedChunkCounts: [MeetingAudioTrack: Int],
        title: String? = nil,
        calendarEventID: String? = nil,
        occurredAtMs: Int64? = nil,
        atlasMeetingID: String? = nil,
        atlasArtifactID: String? = nil,
        state: MeetingLocalRecordingState = .recording,
        durationMs: Int64? = nil,
        sourceGapDetected: Bool = false,
        chunks: [MeetingRecordingChunkDescriptor] = []
    ) {
        self.sessionID = sessionID
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.expectedChunkCounts = expectedChunkCounts
        self.title = title
        self.calendarEventID = calendarEventID
        self.occurredAtMs = occurredAtMs
        self.atlasMeetingID = atlasMeetingID
        self.atlasArtifactID = atlasArtifactID
        self.state = state
        self.durationMs = durationMs
        self.sourceGapDetected = sourceGapDetected
        self.chunks = chunks
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, meetingID, createdAt, expectedChunkCounts, title, calendarEventID, occurredAtMs
        case atlasMeetingID, atlasArtifactID
        case state, durationMs, sourceGapDetected, chunks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.meetingID = try container.decodeIfPresent(String.self, forKey: .meetingID)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.expectedChunkCounts = try container.decode([MeetingAudioTrack: Int].self, forKey: .expectedChunkCounts)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        self.occurredAtMs = try container.decodeIfPresent(Int64.self, forKey: .occurredAtMs)
        self.atlasMeetingID = try container.decodeIfPresent(String.self, forKey: .atlasMeetingID)
        self.atlasArtifactID = try container.decodeIfPresent(String.self, forKey: .atlasArtifactID)
        self.state = try container.decodeIfPresent(MeetingLocalRecordingState.self, forKey: .state) ?? .recording
        self.durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs)
        self.sourceGapDetected = try container.decodeIfPresent(Bool.self, forKey: .sourceGapDetected) ?? false
        self.chunks = try container.decodeIfPresent([MeetingRecordingChunkDescriptor].self, forKey: .chunks) ?? []
    }

    public var pendingChunks: [MeetingRecordingChunkDescriptor] {
        chunks.filter { $0.uploadState == .pending }
    }

    public var isCompleteLocally: Bool {
        expectedChunkCounts.allSatisfy { track, expected in
            chunks.filter { $0.track == track }.count == expected
        }
    }

    public mutating func attachAtlasReferences(meetingID: String, artifactID: String) {
        atlasMeetingID = meetingID
        atlasArtifactID = artifactID
    }
}

public enum MeetingSpeakerResolution: String, Codable, Sendable {
    case selfSpeaker = "self"
    case googleMeet = "google_meet"
    case diarized
    case manual
    case unknown
}

public struct MeetingSpeakerIdentity: Codable, Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let resolution: MeetingSpeakerResolution

    public static let microphone = MeetingSpeakerIdentity(
        key: "microphone",
        displayName: "You",
        resolution: .selfSpeaker
    )

    public static func diarized(key: String, index: Int) -> MeetingSpeakerIdentity {
        let safeIndex = max(1, index)
        return MeetingSpeakerIdentity(
            key: key.isEmpty ? "diarized-\(safeIndex)" : key,
            displayName: "Speaker \(safeIndex)",
            resolution: .diarized
        )
    }

    public static func unknown(key: String = "unknown") -> MeetingSpeakerIdentity {
        MeetingSpeakerIdentity(
            key: key.isEmpty ? "unknown" : key,
            displayName: "Unknown speaker",
            resolution: .unknown
        )
    }

    public static func manual(key: String, displayName: String) -> MeetingSpeakerIdentity {
        MeetingSpeakerIdentity(
            key: key.isEmpty ? "manual" : key,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Unknown speaker"
                : displayName,
            resolution: .manual
        )
    }
}

public struct MeetingSpeakerTurn: Codable, Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let speaker: MeetingSpeakerIdentity

    public init(startMs: Int64, endMs: Int64, text: String, speaker: MeetingSpeakerIdentity) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speaker = speaker
    }
}
