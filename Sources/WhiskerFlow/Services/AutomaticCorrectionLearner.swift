import Foundation
import WhiskerFlowCore

/// One bounded, in-memory queue. Dictation pre-empts assessment on the shared
/// model, and unvalidated edits are never persisted as corrections.
@MainActor
final class AutomaticCorrectionLearner {
    struct Pending {
        let revision = UUID()
        let sessionID: UUID
        let application: String
        let edit: CorrectionEdit
    }

    var assess: (CorrectionEdit) async throws -> [VocabularyCorrection] = { _ in [] }
    var onValidated: (Pending, [VocabularyCorrection]) -> Void = { _, _ in }
    private var pending: [Pending] = []
    private var task: Task<Void, Never>?
    private var activeSession: UUID?
    private var busy = false
    private var enabled = false
    private let debounce: Duration

    init(debounce: Duration = .seconds(2)) { self.debounce = debounce }

    func configure(enabled: Bool) {
        self.enabled = enabled
        if !enabled { pending.removeAll(); task?.cancel() }
        else { resume() }
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        if busy { task?.cancel() }
        else { resume() }
    }

    func enqueue(original: String, edited: String, sessionID: UUID, application: String) {
        guard enabled else { return }
        let edit = original.count <= 12_000 && edited.count <= 12_000
            ? CorrectionEdit(original: original, edited: edited) : CorrectionEdit(original: "", edited: "")
        pending.removeAll { $0.sessionID == sessionID }
        pending.append(Pending(sessionID: sessionID, application: application, edit: edit))
        if pending.count > 20 { pending.removeFirst(pending.count - 20) }
        if activeSession == sessionID { task?.cancel() }
        resume()
    }

    func resume() {
        guard enabled, !busy, task == nil, !pending.isEmpty else { return }
        task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.activeSession = nil
                // A newer revision or a dictation may have cancelled this task.
                if Task.isCancelled { self.resume() }
            }
            do {
                try await Task.sleep(for: self.debounce)
                while self.enabled, !self.busy, let next = self.pending.first {
                    try Task.checkCancellation()
                    self.activeSession = next.sessionID
                    let approved = next.edit.candidates.isEmpty ? [] : try await self.assess(next.edit)
                    try Task.checkCancellation()
                    guard self.pending.first?.revision == next.revision else { continue }
                    self.pending.removeFirst()
                    // Never accept a pair invented by a classifier.
                    self.onValidated(next, approved.filter { next.edit.candidates.contains($0) })
                }
            } catch {
                // Unavailable models leave the queue in memory for the next
                // dictation or edit. No timer retries or fallback learning.
            }
        }
    }

    func stop() { enabled = false; pending.removeAll(); task?.cancel() }
    deinit { task?.cancel() }
}
