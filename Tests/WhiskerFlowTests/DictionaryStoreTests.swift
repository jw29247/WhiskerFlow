import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstLaunchMigratesLegacyVocabularyAndLeavesTheOriginalInPlace() throws {
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = Vocabulary(rules: [VocabularyRule(find: "clawed", replaceWith: "Claude"),
                                        VocabularyRule(find: "iphone", replaceWith: "iPhone")])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "vocabulary")
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))

        let url = root.appendingPathComponent("dictionary.json")
        let store = DictionaryStore(fileURL: url, legacyVocabulary: settings.vocabulary)
        XCTAssertEqual(store.entries.map(\.written), ["Claude", "iPhone"])
        XCTAssertEqual(store.entries.map(\.kind), [.replacement, .word])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(Vocabulary.self, from: XCTUnwrap(defaults.data(forKey: "vocabulary"))), legacy,
                       "the legacy copy stays for older builds")

        // Later launches read the file, not the legacy vocabulary again.
        store.remove(store.entries[0].id)
        XCTAssertEqual(DictionaryStore(fileURL: url, legacyVocabulary: legacy).entries.map(\.written), ["iPhone"])
    }

    func testCorruptFileIsKeptAndLegacyRulesStillApply() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("dictionary.json")
        let original = Data("not json".utf8)
        try original.write(to: url)
        let store = DictionaryStore(fileURL: url, legacyVocabulary: Vocabulary(rules: [VocabularyRule(find: "clawed", replaceWith: "Claude")]))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.vocabulary.apply(to: "clawed"), "Claude")
        store.add(.word("Figma"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLearnedHintsAreNotBlindReplacementsWhenCleanupIsOff() {
        let dictionary = DictionaryStore()
        dictionary.add(.replacement("whisper", "WhiskerFlow", origin: .learned))
        dictionary.add(.replacement("clawed", "Claude", origin: .manual))
        let text = "Please whisper to clawed."
        XCTAssertEqual(dictionary.explicitVocabulary.apply(to: text), "Please whisper to Claude.")
        XCTAssertEqual(dictionary.vocabulary.rules.count, 2)
        let state = makeState(store: TranscriptStore(fileURL: root.appendingPathComponent("history.json")), dictionary: dictionary)
        XCTAssertEqual(state.dictationVocabulary(usesCleanup: false, includesClient: false).apply(to: text), "Please whisper to Claude.")
        XCTAssertTrue(state.dictationVocabulary(usesCleanup: true, includesClient: false).rules.contains { $0.find == "whisper" && $0.replaceWith == "WhiskerFlow" })
    }

    func testBlankMigratedEntryIsDroppedOnLoad() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("dictionary.json")
        let blank = DictionaryEntry(id: UUID(), kind: .replacement, heard: "", written: "", caseSensitive: false,
                                    wholeWord: true, origin: .migrated, addedAt: Date())
        try JSONEncoder().encode(UserDictionary(entries: [blank, .word("Figma")])).write(to: url)
        XCTAssertEqual(DictionaryStore(fileURL: url).entries.map(\.written), ["Figma"])
        XCTAssertEqual(DictionaryStore(fileURL: url).entries.count, 1, "the cleanup was saved")
        XCTAssertTrue(DictionaryStore(fileURL: root.appendingPathComponent("fresh.json"),
                                      legacyVocabulary: Vocabulary(rules: [VocabularyRule(find: "", replaceWith: "")]))
                        .entries.isEmpty, "a blank legacy rule is not migrated")
    }

    func testHistoryEditWaitsForAIAndPersistsOnlyApprovedCorrections() async throws {
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit to send the file.", audioFilePath: "", status: .transcribed)
        try history.add(record)
        let dictionaryURL = root.appendingPathComponent("dictionary.json")
        let state = makeState(store: history, dictionary: DictionaryStore(fileURL: dictionaryURL)) { edit in
            edit.candidates.filter { $0.replaceWith == "Zorblet" }
        }
        state.updateText(record, to: "Ask Zorblet to share the file.")
        XCTAssertTrue(state.dictionary.entries.isEmpty, "no synchronous heuristic learning")
        try await waitForLearning { !state.dictionary.entries.isEmpty }
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorblet"])
        XCTAssertEqual(DictionaryStore(fileURL: dictionaryURL).entries, state.dictionary.entries)
        state.undoDictionaryNotice()
        XCTAssertTrue(state.dictionary.entries.isEmpty)
    }

    func testIntentionalRewriteIsNotLearned() async throws {
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "That was nice work.", audioFilePath: "", status: .transcribed)
        try history.add(record)
        var assessed = false
        let state = makeState(store: history) { _ in assessed = true; return [] }
        state.updateText(record, to: "That was fine work.")
        try await waitForLearning { assessed }
        XCTAssertTrue(state.dictionary.entries.isEmpty)
    }

    func testLaterEditAndUndoReplaceOnlyThisSessionsLearning() async throws {
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit about it.", audioFilePath: "", status: .transcribed)
        try history.add(record)
        let state = makeState(store: history) { $0.candidates }
        state.updateText(record, to: "Ask Zorb about it.")
        try await waitForLearning { state.dictionary.entries.first?.written == "Zorb" }
        state.dictionary.update { $0.entries[0].useCount = 2; $0.entries[0].lastUsedAt = Date() }
        state.updateText(try XCTUnwrap(state.records.first), to: "Ask Zorblet about it.")
        try await waitForLearning { state.dictionary.entries.first?.written == "Zorblet" }
        XCTAssertEqual(state.dictionary.entries.count, 1)
        state.updateText(try XCTUnwrap(state.records.first), to: record.text)
        try await waitForLearning { state.dictionary.entries.isEmpty }
    }

    func testUndoingOneEditKeepsACorrectionConfirmedInAnotherSession() async throws {
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let first = TranscriptRecord(text: "Ask zorbit about it.", audioFilePath: "", status: .transcribed)
        let second = TranscriptRecord(text: first.text, audioFilePath: "", status: .transcribed)
        try history.add(first)
        try history.add(second)
        var calls = 0
        let state = makeState(store: history) { edit in calls += 1; return edit.candidates }
        state.updateText(first, to: "Ask Zorblet about it.")
        try await waitForLearning { calls == 1 && !state.dictionary.entries.isEmpty }
        state.updateText(second, to: "Ask Zorblet about it.")
        try await waitForLearning { calls == 2 }
        state.updateText(try XCTUnwrap(state.records.first { $0.id == first.id }), to: first.text)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorblet"])
    }

    func testLearningDisabledDoesNotRecordEditsOrPromoteLegacyObservations() throws {
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit about it.", audioFilePath: "", status: .transcribed)
        try history.add(record)
        let corrections = CorrectionStore()
        corrections.record([.init(find: "send", replaceWith: "share")], sessionID: UUID(), application: "Notes")
        let state = makeState(store: history)
        state.settings.rememberCorrections = false
        state.configureCleanup()
        state.updateText(record, to: "Ask Zorblet about it.")
        XCTAssertTrue(state.dictionary.entries.isEmpty)
        XCTAssertEqual(corrections.records.count, 1, "old observations are retained without heuristic promotion")
    }

    func testFailedSaveStaysVisibleAndForgetPreventsRelearning() async throws {
        let folder = root.appendingPathComponent("dictionary")
        let dictionary = DictionaryStore(fileURL: folder.appendingPathComponent("dictionary.json"))
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        let history = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit about it.", audioFilePath: "", status: .transcribed)
        try history.add(record)
        let state = makeState(store: history, dictionary: dictionary) { $0.candidates }
        state.updateText(record, to: "Ask Zorblet about it.")
        try await waitForLearning { !dictionary.entries.isEmpty }
        XCTAssertNotNil(dictionary.errorMessage)
        XCTAssertFalse(try XCTUnwrap(state.dictionaryNotice).isSaved)
        let entry = try XCTUnwrap(dictionary.entries.first)
        state.removeCorrection(entry)
        XCTAssertTrue(dictionary.entries.isEmpty)
        XCTAssertTrue(dictionary.dictionary.isRejected(.init(heard: "zorbit", written: "Zorblet")))
    }

    private func waitForLearning(_ finished: () -> Bool) async throws {
        for _ in 0..<80 {
            if finished() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Learning did not finish")
    }

    private func makeState(store: TranscriptStore,
                           dictionary: DictionaryStore? = nil,
                           assess: @escaping (CorrectionEdit) async throws -> [VocabularyCorrection] = { $0.candidates }) -> AppState {
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.cleanupEnabled = true
        return AppState(settings: settings, store: store,
                        dictionaryStore: dictionary ?? DictionaryStore(), correctionAssessor: assess)
    }
}
