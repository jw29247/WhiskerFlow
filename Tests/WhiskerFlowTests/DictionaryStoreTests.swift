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

    func testHistoryCorrectionSeenTwiceIsLearnedAppliedAndUndoable() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let first = TranscriptRecord(text: "Ask zorbit about the launch.", audioFilePath: "", status: .transcribed)
        let second = TranscriptRecord(text: "Zorbit wants the launch moved.", audioFilePath: "", status: .transcribed)
        try store.add(first)
        try store.add(second)
        let state = makeState(store: store)

        state.updateText(first, to: "Ask Zorblet about the launch.")
        XCTAssertTrue(state.dictionary.entries.isEmpty, "one sighting is only a suggestion")
        XCTAssertEqual(state.dictionarySuggestions.map(\.pair.written), ["Zorblet"])

        state.updateText(second, to: "Zorblet wants the launch moved.")
        XCTAssertEqual(state.dictionary.entries.map(\.written), ["Zorblet"])
        XCTAssertEqual(state.dictionary.entries.first?.origin, .learned)
        XCTAssertNotNil(state.dictionaryNotice)
        XCTAssertEqual(state.effectiveVocabulary.apply(to: "zorbit said hi"), "Zorblet said hi")
        XCTAssertTrue(state.recognizerHints.terms.contains("Zorblet"))

        state.undoDictionaryNotice()
        XCTAssertTrue(state.dictionary.entries.isEmpty)
        XCTAssertTrue(state.dictionarySuggestions.isEmpty, "undo also stops it being suggested again")
    }

    func testAutoAddOffLeavesCorrectionsAsSuggestions() throws {
        let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
        let records = (0..<3).map { TranscriptRecord(text: "Call zorbit \($0).", audioFilePath: "", status: .transcribed) }
        try records.forEach { try store.add($0) }
        let state = makeState(store: store)
        state.settings.autoAddLearnedWords = false
        for record in records { state.updateText(record, to: record.text.replacingOccurrences(of: "zorbit", with: "Zorblet")) }
        XCTAssertTrue(state.dictionary.entries.isEmpty)
        let suggestion = try XCTUnwrap(state.dictionarySuggestions.first)
        XCTAssertEqual(suggestion.sightings, 3)
        state.acceptDictionarySuggestion(suggestion)
        XCTAssertEqual(state.dictionary.entries.first?.origin, .manual)
    }

    private func makeState(store: TranscriptStore) -> AppState {
        let name = "WhiskerFlow.dictionary-tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        return AppState(settings: settings, store: store, correctionStore: CorrectionStore(),
                        dictionaryStore: DictionaryStore())
    }
}
