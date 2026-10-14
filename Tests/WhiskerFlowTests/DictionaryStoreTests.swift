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

    func testHistoryCorrectionIsLearnedAppliedAndUndoable() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let first = TranscriptRecord(text: "Ask zorbit about the launch.", audioFilePath: "", status: .transcribed)
        try store.add(first)
        let state = makeState(store: store)

        state.updateText(first, to: "Ask Zorblet about the launch.")
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorblet"])
        XCTAssertEqual(state.dictionary.entries.first?.origin, .learned)
        XCTAssertNotNil(state.dictionaryNotice)
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "zorbit said hi"), "Zorblet said hi")
        XCTAssertTrue(state.recognizerHints.terms.contains("Zorblet"))

        state.undoDictionaryNotice()
        XCTAssertTrue(state.dictionary.entries.isEmpty)
        XCTAssertTrue(state.dictionarySuggestions.isEmpty, "undo also stops it being suggested again")
    }

    func testALaterEditOfTheSameTranscriptReplacesWhatItLearned() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit about the launch.", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let state = makeState(store: store)

        state.updateText(record, to: "Ask Zorb about the launch.")
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorb"], "the half-typed fix was learned")
        let edited = try XCTUnwrap(state.records.first { $0.id == record.id })
        state.updateText(edited, to: "Ask Zorblet about the launch.")
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorblet"], "the finished fix replaces it")
        XCTAssertEqual(state.dictionaryNotice?.changes.map(\.after.written), ["Zorblet"])

        let finished = try XCTUnwrap(state.records.first { $0.id == record.id })
        state.updateText(finished, to: "Ask zorbit about the launch.")
        XCTAssertTrue(state.dictionary.entries.isEmpty, "taking the edit back takes the entry back")
        XCTAssertNil(state.dictionaryNotice)
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

    func testAutoAddOffLeavesCorrectionsAsSuggestions() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let records = (0..<3).map { TranscriptRecord(text: "Call zorbit \($0).", audioFilePath: "", status: .transcribed) }
        try records.forEach { try store.add($0) }
        let state = makeState(store: store)
        state.settings.autoAddLearnedWords = false
        for record in records { state.updateText(record, to: record.text.replacingOccurrences(of: "zorbit", with: "Zorblet")) }
        XCTAssertTrue(state.dictionary.entries.isEmpty)
        XCTAssertFalse(state.pendingVocabularySuggestions.isEmpty, "manual additions remain available with auto-add off")
        let suggestion = try XCTUnwrap(state.dictionarySuggestions.first)
        XCTAssertEqual(suggestion.sightings, 3)
        state.acceptDictionarySuggestion(suggestion)
        XCTAssertEqual(state.dictionary.entries.first?.origin, .manual)
    }

    func testNamesAndAcronymsAreNotOrdinaryWords() {
        for name in ["Heber", "Reese", "Mackay", "CIO", "GEV", "UFI", "Niamh"] {
            XCTAssertFalse(AppState.isKnownWord(name), name)
        }
        for word in ["fire", "Well", "Okay", "flow", "whisper", "grain", "There's"] {
            XCTAssertTrue(AppState.isKnownWord(word), word)
        }
    }

    func testAMisheardNameIsReplacedAfterTheFirstFix() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask Heber about the launch.", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let state = makeState(store: store)

        state.updateText(record, to: "Ask Heba about the launch.")
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "Heber said hi"), "Heba said hi")
        XCTAssertEqual(state.dictionaryNotice?.message, "“Heber” will now be written “Heba”.")
    }

    func testHeldRewritesAreLearnedOnceAtLaunch() {
        let corrections = CorrectionStore()
        corrections.record([VocabularyCorrection(find: "Heber", replaceWith: "Heba")], sessionID: UUID(),
                           application: "Slack")
        let dictionary = DictionaryStore()
        dictionary.add(.word("Heba", origin: .learned))
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: root.appendingPathComponent("history.json")),
                             correctionStore: corrections, dictionaryStore: dictionary)

        state.learnHeldDictionaryRewritesOnce()
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "Heber said hi"), "Heba said hi")
        XCTAssertTrue(settings.dictionaryHeldRewritesLearned)

        state.undoDictionaryNotice()
        state.learnHeldDictionaryRewritesOnce()
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "Heber said hi"), "Heber said hi", "the pass runs once")
    }

    func testHistoryCorrectionPersistsAndRewritesAfterRestart() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask Whisper about it.", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let url = root.appendingPathComponent("dictionary.json")
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let state = AppState(settings: settings, store: store, correctionStore: CorrectionStore(),
                             dictionaryStore: DictionaryStore(fileURL: url))

        state.updateText(record, to: "Ask Whisker about it.")
        XCTAssertTrue(state.pendingVocabularySuggestions.isEmpty, "an automatically saved correction should not ask to be added again")
        XCTAssertEqual(DictionaryStore(fileURL: url).vocabulary.apply(to: "Whisper said hi."), "Whisker said hi.")
        XCTAssertNil(state.dictionary.errorMessage)
        state.undoDictionaryNotice()
        XCTAssertEqual(DictionaryStore(fileURL: url).vocabulary.apply(to: "Whisper said hi."), "Whisper said hi.")
    }

    func testHeldRewriteRecoveryWaitsUntilAutoAddIsEnabled() {
        let corrections = CorrectionStore()
        corrections.record([VocabularyCorrection(find: "Heber", replaceWith: "Heba")], sessionID: UUID(), application: "Notes")
        let dictionary = DictionaryStore()
        dictionary.add(.word("Heba", origin: .learned))
        let state = makeState(store: TranscriptStore(fileURL: root.appendingPathComponent("history.json")),
                              corrections: corrections, dictionary: dictionary)
        state.settings.autoAddLearnedWords = false
        state.learnHeldDictionaryRewritesOnce()
        XCTAssertFalse(state.settings.dictionaryHeldRewritesLearned)
        state.settings.autoAddLearnedWords = true
        state.learnHeldDictionaryRewritesOnce()
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "Heber"), "Heba")
    }

    func testFailedDictionarySaveIsNotReportedAsSaved() throws {
        let folder = root.appendingPathComponent("dictionary")
        let dictionary = DictionaryStore(fileURL: folder.appendingPathComponent("dictionary.json"))
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let record = TranscriptRecord(text: "Ask zorbit about it.", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let state = makeState(store: store, dictionary: dictionary)

        state.updateText(record, to: "Ask Zorblet about it.")
        XCTAssertNotNil(dictionary.errorMessage)
        if case .failure = state.status {} else { XCTFail("The save failure must be visible") }
        XCTAssertTrue(try XCTUnwrap(state.dictionaryNotice).message.contains("could not be saved"))
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "zorbit"), "Zorblet", "the correction still works for this session")
        state.undoDictionaryNotice()
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "zorbit"), "zorbit")
    }

    func testHeldRewriteRecoveryRetriesAfterAFailedSave() throws {
        let folder = root.appendingPathComponent("dictionary")
        let url = folder.appendingPathComponent("dictionary.json")
        let dictionary = DictionaryStore(fileURL: url)
        dictionary.add(.word("Heba", origin: .learned))
        let saved = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        let corrections = CorrectionStore()
        corrections.record([VocabularyCorrection(find: "Heber", replaceWith: "Heba")], sessionID: UUID(), application: "Notes")
        let state = makeState(store: TranscriptStore(fileURL: root.appendingPathComponent("history.json")),
                              corrections: corrections, dictionary: dictionary)
        state.learnHeldDictionaryRewritesOnce()
        XCTAssertFalse(state.settings.dictionaryHeldRewritesLearned)
        XCTAssertFalse(try XCTUnwrap(state.dictionaryNotice).isSaved, "recovery must keep Undo available when its save fails")
        state.undoDictionaryNotice()
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "Heber"), "Heber")

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saved.write(to: url)
        let restarted = AppState(settings: state.settings, store: TranscriptStore(fileURL: root.appendingPathComponent("history.json")),
                                 correctionStore: corrections, dictionaryStore: DictionaryStore(fileURL: url))
        restarted.learnHeldDictionaryRewritesOnce()
        XCTAssertTrue(restarted.settings.dictionaryHeldRewritesLearned)
        XCTAssertEqual(DictionaryStore(fileURL: url).vocabulary.apply(to: "Heber"), "Heba")
    }

    private func makeState(store: TranscriptStore, corrections: CorrectionStore? = nil,
                           dictionary: DictionaryStore? = nil) -> AppState {
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        return AppState(settings: settings, store: store, correctionStore: corrections ?? CorrectionStore(),
                        dictionaryStore: dictionary ?? DictionaryStore())
    }
}
