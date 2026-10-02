import Foundation
import Logging
import Observation
import ServiceManagement
import WhiskerFlowAppSupport
import WhiskerFlowCore

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let meetingTokenStore: MeetingCaptureTokenStore
    @ObservationIgnored private let logger = Logging.Logger(
        label: "agency.thatworks.WhiskerFlow.Settings"
    )

    private(set) var persistenceError: String?
    /// For state that lives beside the settings (the leaderboard's report marks).
    var userDefaults: UserDefaults { defaults }

    var engine: TranscriptionEngineKind { didSet { defaults.set(engine.rawValue, forKey: Keys.engine) } }
    /// BCP-47 code, or "auto" to let the engine detect.
    var language: String {
        didSet {
            defaults.set(language, forKey: Keys.language)
            formatting.language = language
        }
    }
    /// Write dictation in another language in English (on-device translation).
    var translateToEnglish: Bool { didSet { defaults.set(translateToEnglish, forKey: Keys.translateToEnglish) } }
    var hotkey: HotkeyTrigger { didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) } }
    /// The key combination used when `hotkey == .custom`.
    var customHotkey: KeyCombo { didSet { persist(customHotkey, key: Keys.customHotkey) } }
    var recordingMode: RecordingMode { didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) } }
    /// Show what is being heard in the HUD while speaking. Display only: the
    /// pasted text always comes from the full decode on release.
    var liveTranscription: Bool { didSet { defaults.set(liveTranscription, forKey: Keys.liveTranscription) } }
    /// Press play/pause when dictation starts and again when it stops, only
    /// when something is playing.
    var pauseMediaWhileDictating: Bool { didSet { defaults.set(pauseMediaWhileDictating, forKey: Keys.pauseMediaWhileDictating) } }
    var rememberCorrections: Bool { didSet { defaults.set(rememberCorrections, forKey: "rememberCorrections") } }
    /// Add a remembered correction to the Dictionary as soon as it is seen.
    var autoAddLearnedWords: Bool { didSet { defaults.set(autoAddLearnedWords, forKey: Keys.autoAddLearnedWords) } }
    /// Per-engine recogniser hints from the Dictionary. Each can be turned off
    /// independently; post-recognition replacement applies either way.
    var biasAppleSpeech: Bool { didSet { defaults.set(biasAppleSpeech, forKey: Keys.biasAppleSpeech) } }
    var biasParakeet: Bool { didSet { defaults.set(biasParakeet, forKey: Keys.biasParakeet) } }
    var delivery: DeliveryMode { didSet { defaults.set(delivery.rawValue, forKey: Keys.delivery) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Keys.playSounds) } }
    var allowAppleFallback: Bool { didSet { defaults.set(allowAppleFallback, forKey: Keys.allowAppleFallback) } }
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.showMenuBarExtra) } }
    var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) } }
    /// Stable CoreAudio UID, or `system-default`. Numeric AudioDeviceIDs are never persisted here.
    var selectedInputUID: String { didSet { defaults.set(selectedInputUID, forKey: Keys.selectedInputUID) } }
    /// The pre-Dictionary personal vocabulary. Read once to migrate into
    /// `DictionaryStore` and otherwise left as it was, as a fallback for older builds.
    var vocabulary: Vocabulary { didSet { persist(vocabulary, key: Keys.vocabulary) } }
    /// Carries the dictation language (not persisted) so filler removal can
    /// skip languages the English filler list doesn't fit.
    var formatting: FormattingOptions { didSet { persist(formatting, key: Keys.formatting) } }
    /// Apply changes through `AppState.setHistoryRetention(_:)`, which also prunes.
    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention) }
    }
    /// Opt-in: keep the audio of every dictation from the last 14 days, for
    /// playback and re-transcription. Off keeps only the newest 25 recordings.
    var keepRecentRecordings: Bool {
        didSet { defaults.set(keepRecentRecordings, forKey: Keys.keepRecentRecordings) }
    }
    /// The user's own typing speed, for Insights' time-saved estimate.
    var typingWordsPerMinute: Int {
        didSet { defaults.set(typingWordsPerMinute, forKey: Keys.typingWordsPerMinute) }
    }

    /// Atlas is the production service used by Meeting Mode. The connection
    /// token returned after Clerk sign-in remains in Keychain.
    var atlasBaseURL: String { Self.atlasProductionURL }
    var meetingModeEnabled: Bool { didSet { defaults.set(meetingModeEnabled, forKey: Keys.meetingModeEnabled) } }
    /// Show "Record this meeting?" when a call starts in a call app or browser.
    var askToRecordCalls: Bool { didSet { defaults.set(askToRecordCalls, forKey: Keys.askToRecordCalls) } }
    /// The private meeting coach. On by default and remembered.
    var coachEnabled: Bool { didSet { defaults.set(coachEnabled, forKey: Keys.coachEnabled) } }
    /// Speaking pace from on-device transcription of your microphone while coaching.
    var coachLiveAnalysis: Bool { didSet { defaults.set(coachLiveAnalysis, forKey: Keys.coachLiveAnalysis) } }
    /// Experimental on-device AI coaching suggestions. On by default; they run
    /// only where Apple's on-device model is available.
    var coachAISuggestions: Bool { didSet { defaults.set(coachAISuggestions, forKey: Keys.coachAISuggestions) } }
    /// How long delivered meeting transcripts stay in the library on this Mac.
    var meetingTranscriptRetention: MeetingTranscriptRetention {
        didSet { defaults.set(meetingTranscriptRetention.rawValue, forKey: Keys.meetingTranscriptRetention) }
    }

    /// Keychain reads are synchronous securityd IPC. Only this setter writes
    /// the token, so a read-through cache of a definite answer (the token, or
    /// none) stays authoritative.
    @ObservationIgnored private var cachedAtlasDeviceToken: String?

    var atlasDeviceToken: String {
        get {
            if let cachedAtlasDeviceToken { return cachedAtlasDeviceToken }
            switch meetingTokenStore.lookup() {
            case .found(let token):
                cachedAtlasDeviceToken = token
                return token
            case .missing, .denied:
                // A declined access prompt is an answer for this run; asking
                // again on every read would repeat the prompt.
                cachedAtlasDeviceToken = ""
                return ""
            case .unavailable(let status):
                // Not cached: a locked Keychain is not a sign-out. The next
                // read, at the latest when the app is next activated, retries.
                logger.warning("Atlas token read failed", metadata: ["status": "\(status)"])
                return ""
            }
        }
        set {
            cachedAtlasDeviceToken = nil
            do {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try meetingTokenStore.delete()
                } else {
                    try meetingTokenStore.write(trimmed)
                }
                cachedAtlasDeviceToken = trimmed
                persistenceError = nil
            } catch {
                reportPersistenceFailure(error)
            }
        }
    }

    func cachedMeetingSchedule() -> [AtlasCaptureScheduleIntent] {
        guard let data = defaults.data(forKey: Keys.cachedMeetingSchedule) else { return [] }
        return (try? JSONDecoder().decode([AtlasCaptureScheduleIntent].self, from: data)) ?? []
    }

    func cacheMeetingSchedule(_ intents: [AtlasCaptureScheduleIntent]) {
        let bounded = Array(intents.prefix(50))
        // Polling unchanged schedules must not repeatedly invoke preferences KVO
        // and persistence on the UI thread. Compare decoded values, since JSON
        // object key ordering is not stable between encodes.
        if let existing = defaults.data(forKey: Keys.cachedMeetingSchedule),
           let cached = try? JSONDecoder().decode([AtlasCaptureScheduleIntent].self, from: existing),
           cached == bounded {
            return
        }
        do {
            let data = try JSONEncoder().encode(bounded)
            defaults.set(data, forKey: Keys.cachedMeetingSchedule)
            persistenceError = nil
        } catch {
            reportPersistenceFailure(error)
        }
    }

    @ObservationIgnored private(set) var legacySelectedDeviceID: String?
    /// Whether this install launched before this process: read before `init`
    /// writes its one-shot migration flags, which every launch sets.
    @ObservationIgnored let hadPreviousLaunch: Bool

    /// Parakeet refuses to run off Apple Silicon; Apple Speech is the only
    /// engine there.
    private static var supportsParakeet: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if !UIPreview.isEnabled { applyLaunchAtLogin(launchAtLogin) }
        }
    }

    init(defaults: UserDefaults = .standard, meetingTokenStore: MeetingCaptureTokenStore = MeetingCaptureTokenStore()) {
        self.defaults = defaults
        self.meetingTokenStore = meetingTokenStore
        hadPreviousLaunch = defaults.object(forKey: Keys.languageAutoMigrated) != nil

        // Whisper was removed: a stored Whisper engine moves to Parakeet, and
        // its model size and command-line settings are dropped.
        let storedEngine = defaults.string(forKey: Keys.engine)
        let storedChoice = TranscriptionEngineKind.engineForStoredPreferences(rawValue: storedEngine)
        let resolvedEngine = Self.supportsParakeet
            ? (TranscriptionEngineKind.selectableCases.contains(storedChoice) ? storedChoice : .defaultEngine)
            : .appleSpeech
        engine = resolvedEngine
        if storedEngine != resolvedEngine.rawValue, storedEngine != nil {
            defaults.set(resolvedEngine.rawValue, forKey: Keys.engine)
        }
        for key in Keys.removedWhisperSettings { defaults.removeObject(forKey: key) }
        let initialLanguage = Self.migratedLanguage(from: defaults)
        language = initialLanguage
        translateToEnglish = defaults.object(forKey: Keys.translateToEnglish) as? Bool ?? true
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyTrigger.init) ?? .fn
        customHotkey = Self.loadCustomHotkey(from: defaults) ?? .default
        recordingMode = defaults.string(forKey: Keys.recordingMode).flatMap(RecordingMode.init) ?? .holdToTalk
        liveTranscription = defaults.object(forKey: Keys.liveTranscription) as? Bool ?? true
        pauseMediaWhileDictating = defaults.object(forKey: Keys.pauseMediaWhileDictating) as? Bool ?? true
        rememberCorrections = defaults.object(forKey: "rememberCorrections") as? Bool ?? true
        autoAddLearnedWords = defaults.object(forKey: Keys.autoAddLearnedWords) as? Bool ?? true
        biasAppleSpeech = defaults.object(forKey: Keys.biasAppleSpeech) as? Bool ?? Self.defaultBiasAppleSpeech
        biasParakeet = defaults.object(forKey: Keys.biasParakeet) as? Bool ?? Self.defaultBiasParakeet
        delivery = defaults.string(forKey: Keys.delivery).flatMap(DeliveryMode.init) ?? .pasteAtCursor
        playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
        allowAppleFallback = defaults.object(forKey: Keys.allowAppleFallback) as? Bool ?? true
        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        selectedInputUID = defaults.string(forKey: Keys.selectedInputUID) ?? "system-default"
        vocabulary = Self.loadVocabulary(from: defaults) ?? Vocabulary()
        var initialFormatting = Self.loadFormatting(from: defaults) ?? FormattingOptions()
        initialFormatting.language = initialLanguage
        formatting = initialFormatting
        historyRetention = Self.migratedHistoryRetention(from: defaults)
        keepRecentRecordings = defaults.object(forKey: Keys.keepRecentRecordings) as? Bool ?? false
        let storedTypingSpeed = defaults.object(forKey: Keys.typingWordsPerMinute) as? Int
        typingWordsPerMinute = storedTypingSpeed.map {
            min(max($0, InsightsSummary.typingWordsPerMinuteRange.lowerBound), InsightsSummary.typingWordsPerMinuteRange.upperBound)
        } ?? InsightsSummary.defaultTypingWordsPerMinute
        defaults.removeObject(forKey: Keys.atlasBaseURL)
        // Meeting Mode is on by default (2 October 2026). Existing installs
        // switch on once, whatever they stored before, and keep any later
        // choice. It records only after "Record this meeting?" or a scheduled
        // opt-in, and needs Atlas; the model is the dictation model.
        if !defaults.bool(forKey: Keys.meetingModeDefaultOnMigrated) {
            defaults.set(true, forKey: Keys.meetingModeEnabled)
            defaults.set(true, forKey: Keys.meetingModeDefaultOnMigrated)
        }
        meetingModeEnabled = defaults.object(forKey: Keys.meetingModeEnabled) as? Bool ?? true
        askToRecordCalls = defaults.object(forKey: Keys.askToRecordCalls) as? Bool ?? true
        coachEnabled = defaults.object(forKey: Keys.coachEnabled) as? Bool ?? true
        coachLiveAnalysis = defaults.object(forKey: Keys.coachLiveAnalysis) as? Bool ?? true
        coachAISuggestions = defaults.object(forKey: Keys.coachAISuggestions) as? Bool ?? true
        meetingTranscriptRetention = defaults.string(forKey: Keys.meetingTranscriptRetention)
            .flatMap(MeetingTranscriptRetention.init(rawValue:)) ?? .defaultValue
        legacySelectedDeviceID = defaults.string(forKey: Keys.selectedDeviceID)
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        defaults.removeObject(forKey: Keys.sharedVocabularyURL)
        // Echo cancellation was removed: it slowed every mic start and could
        // hang CoreAudio. Drop its setting and the hang record it kept.
        defaults.removeObject(forKey: Keys.ignoreSpeakerAudio)
        defaults.removeObject(forKey: Keys.voiceProcessingHungInputs)
    }

    static let atlasProductionURL = "https://atlas.thatworks.agency"

    /// Defaults follow docs/validation/2026-09-25-dictionary-biasing.md.
    static let defaultBiasAppleSpeech = true
    static let defaultBiasParakeet = false

    /// How dictation in the chosen language becomes text.
    var languagePlan: DictationLanguagePlan {
        DictationLanguagePlan(language: language, translateToEnglish: translateToEnglish)
    }

    var resolvedLanguage: String? {
        language.lowercased() == "auto" ? nil : language
    }

    var selectedInput: AudioInputSelection {
        get { AudioInputSelection(persistedValue: selectedInputUID) }
        set { selectedInputUID = newValue.persistedValue }
    }

    func finishLegacyMicrophoneMigration(_ selection: AudioInputSelection) {
        guard legacySelectedDeviceID != nil else { return }
        selectedInput = selection
        defaults.removeObject(forKey: Keys.selectedDeviceID)
        legacySelectedDeviceID = nil
    }

    /// The key combination the monitor should watch for, resolving presets and
    /// the custom shortcut to a single value.
    var activeHotkeyCombo: KeyCombo {
        hotkey.presetCombo ?? customHotkey
    }

    /// Human-readable name for the active hotkey, for status text and prompts.
    var hotkeyDisplayName: String {
        hotkey == .custom ? customHotkey.displayName : hotkey.displayName
    }

    /// The shortcut as it reads in a sentence ("hold fn and speak").
    var hotkeySpokenName: String {
        hotkey == .fn ? "fn" : hotkeyDisplayName
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
            persistenceError = nil
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private func reportPersistenceFailure(_ error: Error) {
        persistenceError = "A setting could not be saved. Try again."
        logger.error(
            "Settings persistence failed",
            metadata: ["error.code": "\((error as NSError).code)"]
        )
        DiagnosticsService.capture(
            error: error,
            category: "storage",
            code: String((error as NSError).code)
        )
    }

    private static func loadVocabulary(from defaults: UserDefaults) -> Vocabulary? {
        guard let data = defaults.data(forKey: Keys.vocabulary) else { return nil }
        return try? JSONDecoder().decode(Vocabulary.self, from: data)
    }

    /// "Auto-detect" used to be decorative: every WhisperKit identifier was the
    /// English-only variant whatever the setting said. It now selects multilingual
    /// weights, which an existing user has never downloaded — so a stored "auto"
    /// from before that change becomes English rather than forcing a
    /// several-hundred-megabyte download (and a dead engine when offline). The
    /// one-shot flag means a user who picks Auto-detect deliberately afterwards
    /// keeps it. Assigning in `init` doesn't run `didSet`, so the value is written
    /// through to `defaults` here. The flag is set on every launch, not just when
    /// migrating, so an "auto" chosen after a fresh install (or after any other
    /// stored language) is never mistaken for the legacy value.
    private static func migratedLanguage(from defaults: UserDefaults) -> String {
        let alreadyMigrated = defaults.bool(forKey: Keys.languageAutoMigrated)
        defaults.set(true, forKey: Keys.languageAutoMigrated)
        guard let stored = defaults.string(forKey: Keys.language) else { return "en" }
        guard stored.lowercased() == "auto", !alreadyMigrated else { return stored }
        defaults.set("en", forKey: Keys.language)
        return "en"
    }

    /// History used to be fixed at 30 days and 25 records. New and existing
    /// installs both start at 90 days: every record an existing user has is
    /// younger than that, so the migration deletes nothing. Written through so a
    /// later default change can't silently shorten an existing user's history.
    private static func migratedHistoryRetention(from defaults: UserDefaults) -> HistoryRetention {
        if let stored = defaults.string(forKey: Keys.historyRetention).flatMap(HistoryRetention.init) { return stored }
        defaults.set(HistoryRetention.defaultValue.rawValue, forKey: Keys.historyRetention)
        return .defaultValue
    }

    private static func loadFormatting(from defaults: UserDefaults) -> FormattingOptions? {
        guard let data = defaults.data(forKey: Keys.formatting) else { return nil }
        return try? JSONDecoder().decode(FormattingOptions.self, from: data)
    }

    private static func loadCustomHotkey(from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: Keys.customHotkey) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private enum Keys {
        static let engine = "engine"
        /// Whisper's model size, command and arguments, its dictionary-hint
        /// switch, and the one-shot WhisperKit-to-Parakeet migration flag.
        static let removedWhisperSettings = [
            "model", "whisperCommand", "whisperArguments", "dictionaryBiasWhisperKit", "parakeetTDTv3DefaultMigrated",
        ]
        static let language = "language"
        static let languageAutoMigrated = "languageAutoMigrated"
        static let hotkey = "hotkey"
        static let customHotkey = "customHotkey"
        static let recordingMode = "recordingMode"
        static let liveTranscription = "liveTranscription"
        static let pauseMediaWhileDictating = "pauseMediaWhileDictating"
        static let translateToEnglish = "translateToEnglish"
        static let ignoreSpeakerAudio = "ignoreSpeakerAudio"
        static let voiceProcessingHungInputs = "voiceProcessingHungInputs"
        static let delivery = "delivery"
        static let playSounds = "playSounds"
        static let allowAppleFallback = "allowAppleFallback"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let showDockIcon = "showDockIcon"
        static let selectedDeviceID = "selectedDeviceID"
        static let selectedInputUID = "selectedInputUID"
        static let vocabulary = "vocabulary"
        static let autoAddLearnedWords = "autoAddLearnedWords"
        static let biasAppleSpeech = "dictionaryBiasAppleSpeech"
        static let biasParakeet = "dictionaryBiasParakeet"
        static let formatting = "formattingOptions"
        static let historyRetention = "historyRetention"
        static let typingWordsPerMinute = "typingWordsPerMinute"
        static let keepRecentRecordings = "keepRecentRecordings"
        static let sharedVocabularyURL = "sharedVocabularyURL"
        static let launchAtLogin = "launchAtLogin"
        static let atlasBaseURL = "atlasBaseURL"
        static let meetingModeEnabled = "meetingModeEnabled"
        static let meetingModeDefaultOnMigrated = "meetingModeDefaultOnMigrated"
        static let meetingTranscriptRetention = "meetingTranscriptRetention"
        static let askToRecordCalls = "askToRecordCalls"
        static let coachEnabled = "coachEnabled"
        static let coachLiveAnalysis = "coachLiveAnalysis"
        static let coachAISuggestions = "coachAISuggestions"
        static let cachedMeetingSchedule = "cachedMeetingSchedule"
    }
}
