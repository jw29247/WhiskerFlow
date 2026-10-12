import Foundation
import Observation
import WhiskerFlowCore

struct SavedCorrection: Codable, Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let original: String
    let replacement: String
    let application: String
    let date: Date

    var suggestion: VocabularyCorrection { .init(find: original, replaceWith: replacement) }
}

/// Stores word pairs only; document content never leaves the temporary paste scope.
@MainActor @Observable
final class CorrectionStore {
    private(set) var records: [SavedCorrection] = []
    private(set) var errorMessage: String?
    private let fileURL: URL?
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            records = Array(try JSONDecoder().decode([SavedCorrection].self, from: Data(contentsOf: fileURL)).prefix(500))
        } catch {
            loadFailed = true
            errorMessage = "Saved corrections could not be opened. The original file has been kept."
        }
    }

    static func defaultStore() -> CorrectionStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CorrectionStore(fileURL: root.appendingPathComponent("WhiskerFlow/Corrections/corrections.json"))
    }

    /// A stable edit replaces this paste's observations, so undo and intermediate
    /// spellings do not accumulate as separate issues.
    func record(_ corrections: [VocabularyCorrection], sessionID: UUID, application: String) {
        let unique = Array(Set(corrections)).sorted { ($0.find, $0.replaceWith) < ($1.find, $1.replaceWith) }
        let previous = records.filter { $0.sessionID == sessionID }
        guard Set(previous.map(\.suggestion)) != Set(unique) else { return }
        let replacements = unique.map { correction in
            previous.first { $0.suggestion == correction } ?? SavedCorrection(
                id: UUID(), sessionID: sessionID, original: correction.find,
                replacement: correction.replaceWith, application: application, date: Date())
        }
        save(Array((replacements + records.filter { $0.sessionID != sessionID }).prefix(500)))
    }

    func remove(_ correction: VocabularyCorrection) {
        save(records.filter { $0.suggestion != correction })
    }

    func clear() { save([]) }

    private func save(_ next: [SavedCorrection]) {
        guard !loadFailed else { return }
        do {
            if let fileURL {
                let folder = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(next).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            records = next
            errorMessage = nil
        } catch {
            errorMessage = "Could not save corrections. Check that local storage is available."
        }
    }
}
