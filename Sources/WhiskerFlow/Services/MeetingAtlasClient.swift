import CryptoKit
import Foundation
import WhiskerFlowAppSupport

struct AtlasCaptureScheduleIntent: Codable, Sendable {
    let eventID: String
    let title: String
    let startMs: Int64
    let endMs: Int64
    let meetingURL: String?
    let location: String?
    let existingMeetingID: String?
    let overlapsPrevious: Bool
}

protocol MeetingAtlasClient: Sendable {
    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent]
    func heartbeat(
        appVersion: String,
        permissionState: [String: String],
        diskState: String,
        captureState: String,
        lastFailureReason: String?
    ) async throws
    func createMeeting(
        captureSessionID: UUID,
        title: String,
        occurredAtMs: Int64,
        eventID: String?
    ) async throws -> (meetingID: String, created: Bool)
    func prepareRecording(
        meetingID: String,
        captureSessionID: UUID,
        trackChunkCounts: [MeetingAudioTrack: Int],
        sourceManifestHash: String?
    ) async throws -> String
    func uploadChunk(
        artifactID: String,
        descriptor: MeetingRecordingChunkDescriptor,
        body: Data
    ) async throws
    func completeRecording(
        artifactID: String,
        durationMs: Int64,
        trackChunkCounts: [MeetingAudioTrack: Int],
        hasSourceGap: Bool,
        missingTracks: [MeetingAudioTrack],
        canonicalChecksum: String?,
        modelVersion: String?
    ) async throws
    func appendSegments(meetingID: String, turns: [MeetingSpeakerTurn]) async throws
    func finalize(
        meetingID: String,
        artifactID: String,
        transcriptionState: String,
        status: String
    ) async throws
}

enum MeetingAtlasClientError: LocalizedError {
    case notPaired
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair WhiskerFlow with Atlas to enable Meeting Mode."
        case .invalidResponse: return "Atlas returned an invalid meeting capture response."
        case .server(let message): return message
        }
    }
}

final class URLSessionMeetingAtlasClient: MeetingAtlasClient, @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func schedule(fromMs: Int64, toMs: Int64) async throws -> [AtlasCaptureScheduleIntent] {
        let data = try await call(
            tool: "notetaker.schedule",
            args: ["fromMs": fromMs, "toMs": toMs, "limit": 50]
        )
        guard let rows = data as? [[String: Any]] else { throw MeetingAtlasClientError.invalidResponse }
        return rows.compactMap { row in
            guard let eventID = row["eventId"] as? String,
                  let title = row["title"] as? String,
                  let startMs = row["startMs"] as? Int64 ?? (row["startMs"] as? NSNumber)?.int64Value,
                  let endMs = row["endMs"] as? Int64 ?? (row["endMs"] as? NSNumber)?.int64Value else { return nil }
            return AtlasCaptureScheduleIntent(
                eventID: eventID,
                title: title,
                startMs: startMs,
                endMs: endMs,
                meetingURL: row["meetingUrl"] as? String,
                location: row["location"] as? String,
                existingMeetingID: row["existingMeetingId"] as? String,
                overlapsPrevious: row["overlapsPrevious"] as? Bool ?? false
            )
        }
    }

    func heartbeat(
        appVersion: String,
        permissionState: [String: String],
        diskState: String,
        captureState: String,
        lastFailureReason: String?
    ) async throws {
        var args: [String: Any] = [
            "appVersion": appVersion,
            "permissionState": permissionState,
            "diskState": diskState,
            "captureState": captureState,
        ]
        if let lastFailureReason { args["lastFailureReason"] = lastFailureReason }
        _ = try await call(tool: "notetaker.heartbeat", args: args)
    }

    func createMeeting(captureSessionID: UUID, title: String, occurredAtMs: Int64, eventID: String?) async throws -> (meetingID: String, created: Bool) {
        var args: [String: Any] = [
            "externalRef": "create-\(captureSessionID.uuidString)",
            "captureSessionId": captureSessionID.uuidString,
            "contextType": "general",
            "title": title,
            "occurredAtMs": occurredAtMs,
        ]
        if let eventID { args["calendarEventId"] = eventID }
        let response = try await call(
            tool: "notetaker.createMeeting",
            args: args
        )
        guard let row = response as? [String: Any], let meetingID = row["meetingId"] as? String else {
            throw MeetingAtlasClientError.invalidResponse
        }
        return (meetingID, row["created"] as? Bool ?? false)
    }

    func prepareRecording(
        meetingID: String,
        captureSessionID: UUID,
        trackChunkCounts: [MeetingAudioTrack: Int],
        sourceManifestHash: String?
    ) async throws -> String {
        let tracks = trackChunkCounts.map { ["track": $0.key.rawValue, "expectedChunkCount": $0.value] }
        var args: [String: Any] = [
            "meetingId": meetingID,
            "captureSessionId": captureSessionID.uuidString,
            "tracks": tracks,
        ]
        if let sourceManifestHash, !sourceManifestHash.isEmpty {
            args["sourceManifestHash"] = sourceManifestHash
        }
        let response = try await call(
            tool: "notetaker.prepareRecording",
            args: args
        )
        guard let row = response as? [String: Any], let artifactID = row["artifactId"] as? String else {
            throw MeetingAtlasClientError.invalidResponse
        }
        return artifactID
    }

    func uploadChunk(artifactID: String, descriptor: MeetingRecordingChunkDescriptor, body: Data) async throws {
        let url = baseURL.appendingPathComponent("api/notetaker/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int(Date().timeIntervalSince1970 * 1_000)), forHTTPHeaderField: "x-request-timestamp")
        request.setValue(artifactID, forHTTPHeaderField: "x-recording-artifact-id")
        request.setValue(descriptor.track.rawValue, forHTTPHeaderField: "x-recording-track")
        request.setValue(String(descriptor.sequence), forHTTPHeaderField: "x-recording-sequence")
        request.setValue(String(body.count), forHTTPHeaderField: "x-recording-byte-size")
        let checksum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        request.setValue(checksum, forHTTPHeaderField: "x-recording-checksum")
        request.setValue(String(descriptor.startMs), forHTTPHeaderField: "x-recording-start-ms")
        request.setValue(String(descriptor.endMs), forHTTPHeaderField: "x-recording-end-ms")
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func completeRecording(artifactID: String, durationMs: Int64, trackChunkCounts: [MeetingAudioTrack: Int], hasSourceGap: Bool, missingTracks: [MeetingAudioTrack], canonicalChecksum: String?, modelVersion: String?) async throws {
        var args: [String: Any] = [
            "externalRef": "complete-\(artifactID)-\(durationMs)",
            "artifactId": artifactID,
            "durationMs": durationMs,
            "trackChunkCounts": trackChunkCounts.map { ["track": $0.key.rawValue, "chunkCount": $0.value] },
            "hasSourceGap": hasSourceGap,
            "missingTracks": missingTracks.map(\.rawValue),
        ]
        if let canonicalChecksum { args["canonicalChecksum"] = canonicalChecksum }
        if let modelVersion { args["modelVersion"] = modelVersion }
        _ = try await call(
            tool: "notetaker.completeRecording",
            args: args
        )
    }

    func appendSegments(meetingID: String, turns: [MeetingSpeakerTurn]) async throws {
        let segments = turns.map { turn in
            [
                "speakerLabel": turn.speaker.displayName,
                "speakerKey": turn.speaker.key,
                "speakerDisplayName": turn.speaker.displayName,
                "speakerResolution": turn.speaker.resolution.rawValue,
                "speakerProvider": {
                    switch turn.speaker.resolution {
                    case .selfSpeaker: return "whisperkit"
                    case .googleMeet: return "google_meet"
                    case .manual: return "manual"
                    case .diarized, .unknown: return "speakerkit"
                    }
                }(),
                "startMs": turn.startMs,
                "endMs": turn.endMs,
                "text": turn.text,
            ] as [String: Any]
        }
        for (batchIndex, batch) in stride(from: 0, to: segments.count, by: 100)
            .map({ Array(segments[$0..<min($0 + 100, segments.count)]) })
            .enumerated() {
            _ = try await call(
                tool: "notetaker.appendSegments",
                args: [
                    "externalRef": "segments-\(meetingID)-\(batchIndex)",
                    "meetingId": meetingID,
                    "segments": batch,
                ]
            )
        }
    }

    func finalize(meetingID: String, artifactID: String, transcriptionState: String, status: String) async throws {
        _ = try await call(
            tool: "notetaker.finalize",
            args: [
                "externalRef": "finalize-\(artifactID)",
                "meetingId": meetingID,
                "artifactId": artifactID,
                "status": status,
                "transcriptionState": transcriptionState,
            ]
        )
    }

    private func call(tool: String, args: [String: Any]) async throws -> Any {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/notetaker"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "args": args], options: [.fragmentsAllowed])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int(Date().timeIntervalSince1970 * 1_000)), forHTTPHeaderField: "x-request-timestamp")
        let (body, response) = try await session.data(for: request)
        try validate(response)
        guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              envelope["ok"] as? Bool == true,
              let value = envelope["value"] else {
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            throw MeetingAtlasClientError.server(message ?? "Atlas rejected the capture request")
        }
        return value
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MeetingAtlasClientError.server("Atlas capture request failed")
        }
    }
}
