import XCTest
@testable import WhiskerFlowCore

final class UserDictionaryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Migration

    func testMigrationKeepsEveryRuleIdFlagAndText() {
        let long = String(repeating: "x", count: 80)
        let rules = [
            VocabularyRule(find: "clawed", replaceWith: "Claude"),
            VocabularyRule(find: "iphone", replaceWith: "iPhone"),
            VocabularyRule(find: "GPU", replaceWith: "graphics card", caseSensitive: true, wholeWord: false),
            VocabularyRule(find: "Sql", replaceWith: "SQL", caseSensitive: true),
            VocabularyRule(find: long, replaceWith: "short")
        ]
        let dictionary = UserDictionary.migrating(from: Vocabulary(rules: rules), at: date)

        XCTAssertEqual(dictionary.entries.map(\.id), rules.map(\.id))
        XCTAssertEqual(dictionary.entries.map(\.kind), [.replacement, .word, .replacement, .replacement, .replacement])
        XCTAssertEqual(dictionary.entries[1].written, "iPhone")
        XCTAssertEqual(dictionary.entries[1].heard, "", "a word has no heard side")
        XCTAssertTrue(dictionary.entries[2].caseSensitive)
        XCTAssertFalse(dictionary.entries[2].wholeWord)
        XCTAssertEqual(dictionary.entries[3].kind, .replacement, "a case-sensitive casing rule keeps its flag")
        XCTAssertEqual(dictionary.entries[4].heard, long, "over-long legacy text is kept, not truncated")
        XCTAssertTrue(dictionary.entries.allSatisfy { $0.origin == .migrated })

        // The migrated dictionary rewrites text exactly as the old vocabulary did.
        let sample = "clawed said the iphone GPUs beat Sql and \(long)"
        XCTAssertEqual(dictionary.vocabulary.apply(to: sample), Vocabulary(rules: rules).apply(to: sample))
    }

    func testDictionaryDecodesWithMissingFieldsAndRoundTrips() throws {
        let legacy = #"{"entries":[{"written":"Figma"}]}"#
        let decoded = try JSONDecoder().decode(UserDictionary.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.entries.first?.written, "Figma")
        XCTAssertEqual(decoded.entries.first?.kind, .replacement)
        var dictionary = UserDictionary(entries: [.word("Figma", addedAt: date)])
        dictionary.reject(DictionaryPair(heard: "a", written: "b"))
        let data = try JSONEncoder().encode(dictionary)
        XCTAssertEqual(try JSONDecoder().decode(UserDictionary.self, from: data), dictionary)
    }

    // MARK: Rules

    func testWordFixesCasingAndAbsorbedMisspellingsOnly() {
        let word = DictionaryEntry.word("Kubernetes", variants: ["kubernetis"])
        let vocabulary = UserDictionary(entries: [word]).vocabulary
        XCTAssertEqual(vocabulary.apply(to: "deploy to kubernetes and kubernetis"),
                       "deploy to Kubernetes and Kubernetes")
        XCTAssertEqual(vocabulary.apply(to: "kubernetesy stays"), "kubernetesy stays", "whole word only")
    }

    func testReplacementsRunBeforeWordsSoWordsCaseTheirOutput() {
        let dictionary = UserDictionary(entries: [
            .word("WhiskerFlow"),
            .replacement("whisker flow", "whiskerflow")
        ])
        XCTAssertEqual(dictionary.vocabulary.apply(to: "open whisker flow"), "open WhiskerFlow")
    }

    func testValidationEnforcesSixtyCharacters() {
        XCTAssertNil(DictionaryEntry.word(String(repeating: "a", count: 60)).validationProblem)
        XCTAssertEqual(DictionaryEntry.word(String(repeating: "a", count: 61)).validationProblem, .tooLong)
        XCTAssertEqual(DictionaryEntry.replacement(String(repeating: "a", count: 61), "b").validationProblem, .tooLong)
        XCTAssertEqual(DictionaryEntry.replacement("", "b").validationProblem, .missingHeard)
        XCTAssertEqual(DictionaryEntry.word("  ").validationProblem, .missingWritten)
    }

    // MARK: Usage

    func testUsageCountsReplacementsOnRawAndWordsOnFinalText() {
        let replacement = DictionaryEntry.replacement("clawed", "Claude")
        let word = DictionaryEntry.word("Figma", variants: ["figmer"])
        let unused = DictionaryEntry.word("Sketch")
        let raw = "clawed opened figmer then Clawed opened figma"
        let final = "Claude opened Figma then Claude opened Figma"
        let counts = DictionaryUsage.counts(for: [replacement, word, unused], raw: raw, final: final)
        XCTAssertEqual(counts[replacement.id], 2)
        XCTAssertEqual(counts[word.id], 3, "two Figmas in the final text plus one repaired misspelling")
        XCTAssertNil(counts[unused.id])

        var dictionary = UserDictionary(entries: [replacement, word, unused])
        DictionaryUsage.record(counts, readOnly: ["k": 1], in: &dictionary, at: date)
        XCTAssertEqual(dictionary.entries[0].useCount, 2)
        XCTAssertEqual(dictionary.entries[0].lastUsedAt, date)
        XCTAssertNil(dictionary.entries[2].lastUsedAt)
        XCTAssertEqual(dictionary.readOnlyUsage["k"], DictionaryUsageStat(count: 1, lastUsedAt: date))
    }

    // MARK: Biasing terms

    func testBiasTermsRankPersonalFirstAndDeduplicate() {
        var starred = DictionaryEntry.replacement("sio ban", "Siobhan")
        starred.starred = true
        var used = DictionaryEntry.word("Figma")
        used.useCount = 9
        let terms = DictionaryBiasing.terms(
            personal: [.word("Atlas"), used, starred, .replacement("x", "")],
            readOnly: [VocabularyRule(find: "figma", replaceWith: "figma"), VocabularyRule(find: "thatworks", replaceWith: "thatworks")],
            limit: 4)
        XCTAssertEqual(terms, ["Siobhan", "Figma", "Atlas", "thatworks"])
    }

    // MARK: CSV

    func testCSVRoundTripPreservesEntries() throws {
        var starred = DictionaryEntry.replacement("=cmd", "Command, \"quoted\"\nline", caseSensitive: true, wholeWord: false)
        starred.starred = true
        let entries = [
            DictionaryEntry.word("Kubernetes", variants: ["kubernetis", "cooper netties"]),
            starred,
            DictionaryEntry.replacement("-1", "minus one"),
            DictionaryEntry.word("naïve café")
        ]
        let csv = DictionaryCSV.export(entries)
        XCTAssertTrue(csv.contains("'=cmd"), "formula-leading cells are neutralised for spreadsheets")
        let report = try DictionaryCSV.importEntries(from: csv, at: date)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.duplicateCount, 0)
        func shape(_ e: DictionaryEntry) -> [String] {
            [e.kind.rawValue, e.heard, e.written, "\(e.caseSensitive)", "\(e.wholeWord)", "\(e.starred)", e.variants.joined(separator: "|")]
        }
        XCTAssertEqual(report.entries.map(shape), entries.map(shape))
        XCTAssertTrue(report.entries.allSatisfy { $0.origin == .imported })
    }

    func testCSVImportSkipsDuplicatesAndReportsBadRows() throws {
        let csv = """
        written,heard,type
        Figma,,word
        Figma,,word
        Claude,clawed,
        \(String(repeating: "a", count: 61)),,word
        Thing,thing,gadget

        Atlas,,
        """
        let report = try DictionaryCSV.importEntries(from: csv, existing: [.word("Atlas")], at: date)
        XCTAssertEqual(report.entries.map(\.written), ["Figma", "Claude"])
        XCTAssertEqual(report.entries.map(\.kind), [.word, .replacement])
        XCTAssertEqual(report.duplicateCount, 2)
        XCTAssertEqual(report.problems.map(\.line), [5, 6])
        XCTAssertThrowsError(try DictionaryCSV.importEntries(from: "a,b\n1,2")) {
            XCTAssertEqual($0 as? DictionaryCSV.ImportError, .missingHeader)
        }
    }
}
