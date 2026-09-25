import Foundation
import WhiskerFlowAppSupport

@MainActor
final class MeetingBrowserCapture {
    private var task: Task<Void, Never>?
    func start(sessionID: UUID, startMs: Int64, store: EncryptedMeetingChunkStore) {
        task?.cancel()
        task = Task.detached(priority: .utility) {
            guard let config = try? MeetingBrowserInbox.begin(sessionID: sessionID, startMs: startMs) else { return }
            defer { MeetingBrowserInbox.end(config) }
            var meetingCode: String?
            while !Task.isCancelled {
                try? MeetingBrowserInbox.refresh(config)
                let batches = (try? MeetingBrowserInbox.drain(config)) ?? []
                let codes = Set(batches.map(\.meetingCode))
                if meetingCode == nil, codes.count == 1 { meetingCode = codes.first }
                // A second meeting never reuses the first meeting's recording identity.
                if codes.count <= 1 {
                    let rows = batches.filter { $0.meetingCode == meetingCode }.flatMap { batch in
                        batch.samples.compactMap { sample -> MeetingSpeakerEvidence? in
                            let end = sample.atMs - startMs
                            guard end >= 250, sample.atMs <= MeetingBrowserInbox.nowMs + 500 else { return nil }
                            return MeetingSpeakerEvidence(startMs: end - 250, endMs: end, participantID: sample.participantID, displayName: sample.displayName)
                        }
                    }
                    try? store.saveSpeakerEvidence(sessionID: sessionID, evidence: rows)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }
}
