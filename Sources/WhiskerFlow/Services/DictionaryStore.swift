import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// The personal Dictionary, persisted beside the correction log on this Mac.
///
/// On first launch the pre-Dictionary vocabulary (a UserDefaults blob) is
/// migrated into it. That blob is left in place untouched, so going back to an
/// older build still finds the user's rules.
@MainActor @Observable
final class DictionaryStore {
    private(set) var dictionary: UserDictionary
    private(set) var errorMessage: String?
    @ObservationIgnored private let fileURL: URL?
    /// An unreadable file is never overwritten: the original is kept for
    /// recovery, and the legacy vocabulary keeps dictation working meanwhile.
    @ObservationIgnored private var loadFailed = false

    init(fileURL: URL? = nil, legacyVocabulary: Vocabulary = Vocabulary(), now: Date = Date()) {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                dictionary = try JSONDecoder().decode(UserDictionary.self, from: Data(contentsOf: fileURL))
                // Earlier builds migrated a blank legacy rule as an empty entry.
                var cleaned = dictionary
                cleaned.entries.removeAll { $0.origin == .migrated && $0.heard.isEmpty && $0.written.isEmpty }
                if cleaned != dictionary { save(cleaned) }
            } catch {
                loadFailed = true
                dictionary = .migrating(from: legacyVocabulary, at: now)
                errorMessage = "Your dictionary file could not be opened, so changes won’t be saved. The original file has been kept."
            }
        } else {
            dictionary = .migrating(from: legacyVocabulary, at: now)
            if fileURL != nil { save(dictionary) }
        }
    }

    static func defaultStore(legacyVocabulary: Vocabulary) -> DictionaryStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DictionaryStore(fileURL: root.appendingPathComponent("WhiskerFlow/Dictionary/dictionary.json"),
                               legacyVocabulary: legacyVocabulary)
    }

    var entries: [DictionaryEntry] { dictionary.entries }
    var vocabulary: Vocabulary { dictionary.vocabulary }

    func update(_ change: (inout UserDictionary) -> Void) {
        var next = dictionary
        change(&next)
        guard next != dictionary else { return }
        save(next)
    }

    func add(_ entry: DictionaryEntry) {
        update { $0.entries.append(entry) }
    }

    func replace(_ entry: DictionaryEntry) {
        update { dictionary in
            guard let index = dictionary.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            dictionary.entries[index] = entry
        }
    }

    func remove(_ id: DictionaryEntry.ID) {
        update { $0.entries.removeAll { $0.id == id } }
    }

    func toggleStar(_ id: DictionaryEntry.ID) {
        update { dictionary in
            guard let index = dictionary.entries.firstIndex(where: { $0.id == id }) else { return }
            dictionary.entries[index].starred.toggle()
        }
    }

    private func save(_ next: UserDictionary) {
        guard !loadFailed else {
            // Keep working in memory for this session.
            dictionary = next
            return
        }
        do {
            if let fileURL {
                let folder = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .deferredToDate
                try encoder.encode(next).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            dictionary = next
            errorMessage = nil
        } catch {
            dictionary = next
            errorMessage = "Could not save your dictionary. Check that local storage is available."
        }
    }
}

/// What learning just added, kept until the user undoes or dismisses it.
struct DictionaryNotice: Identifiable, Equatable {
    let id = UUID()
    let changes: [DictionaryChange]
    let isSaved: Bool

    init(changes: [DictionaryChange], isSaved: Bool = true) {
        self.changes = changes
        self.isSaved = isSaved
    }

    var message: String {
        guard isSaved else {
            return "Your correction is active for this session, but could not be saved. Open Dictionary for details."
        }
        guard changes.count == 1, let change = changes.first else {
            return "Added \(changes.count) corrections to your Dictionary."
        }
        if change.rewritesHeard {
            return "“\(change.pair.heard)” will now be written “\(change.after.written)”."
        }
        return "Added “\(change.after.written)” to your Dictionary."
    }

    var hudMessage: String {
        guard isSaved else { return "Dictionary correction could not be saved" }
        guard changes.count == 1, let change = changes.first else { return "Saved \(changes.count) dictionary corrections" }
        if change.rewritesHeard {
            return "“\(change.pair.heard)” → “\(change.after.written)” saved"
        }
        return "Added “\(change.after.written)” to Dictionary"
    }
}
