import Foundation
import Observation
import OSLog
import ServiceManagement
import WhiskerFlowAppSupport
import WhiskerFlowCore

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.thatworks.WhiskerFlow",
        category: "Settings"
    )

    private(set) var persistenceError: String?

    var engine: TranscriptionEngineKind { didSet { defaults.set(engine.rawValue, forKey: Keys.engine) } }
    var model: WhisperModel { didSet { defaults.set(model.rawValue, forKey: Keys.model) } }
    /// BCP-47 code, or "auto" to let the engine detect.
    var language: String { didSet { defaults.set(language, forKey: Keys.language) } }
    var hotkey: HotkeyTrigger { didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) } }
    /// The key combination used when `hotkey == .custom`.
    var customHotkey: KeyCombo { didSet { persist(customHotkey, key: Keys.customHotkey) } }
    var recordingMode: RecordingMode { didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) } }
    /// Stream and transcribe while speaking so the transcript pastes instantly on
    /// release. Applies to the WhisperKit engine; other engines stay file-based.
    var liveTranscription: Bool { didSet { defaults.set(liveTranscription, forKey: Keys.liveTranscription) } }
    var delivery: DeliveryMode { didSet { defaults.set(delivery.rawValue, forKey: Keys.delivery) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Keys.playSounds) } }
    var allowAppleFallback: Bool { didSet { defaults.set(allowAppleFallback, forKey: Keys.allowAppleFallback) } }
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.showMenuBarExtra) } }
    var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) } }
    /// Stable CoreAudio UID, or `system-default`. Numeric AudioDeviceIDs are never persisted here.
    var selectedInputUID: String { didSet { defaults.set(selectedInputUID, forKey: Keys.selectedInputUID) } }
    var whisperCommand: String { didSet { defaults.set(whisperCommand, forKey: Keys.whisperCommand) } }
    var whisperArguments: String { didSet { defaults.set(whisperArguments, forKey: Keys.whisperArguments) } }
    var vocabulary: Vocabulary { didSet { persist(vocabulary, key: Keys.vocabulary) } }

    @ObservationIgnored private(set) var legacySelectedDeviceID: String?

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        engine = defaults.string(forKey: Keys.engine).flatMap(TranscriptionEngineKind.init) ?? .whisperKit
        model = defaults.string(forKey: Keys.model).flatMap(WhisperModel.init) ?? .tiny
        language = defaults.string(forKey: Keys.language) ?? "en"
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyTrigger.init) ?? .fn
        customHotkey = Self.loadCustomHotkey(from: defaults) ?? .default
        recordingMode = defaults.string(forKey: Keys.recordingMode).flatMap(RecordingMode.init) ?? .holdToTalk
        liveTranscription = defaults.object(forKey: Keys.liveTranscription) as? Bool ?? true
        delivery = defaults.string(forKey: Keys.delivery).flatMap(DeliveryMode.init) ?? .pasteAtCursor
        playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
        allowAppleFallback = defaults.object(forKey: Keys.allowAppleFallback) as? Bool ?? true
        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        selectedInputUID = defaults.string(forKey: Keys.selectedInputUID) ?? "system-default"
        whisperCommand = defaults.string(forKey: Keys.whisperCommand) ?? Self.defaultWhisperCommand
        whisperArguments = defaults.string(forKey: Keys.whisperArguments) ?? Self.defaultWhisperArguments
        vocabulary = Self.loadVocabulary(from: defaults) ?? Vocabulary()
        legacySelectedDeviceID = defaults.string(forKey: Keys.selectedDeviceID)
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        defaults.removeObject(forKey: Keys.sharedVocabularyURL)
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

    var cliConfiguration: WhisperConfiguration {
        WhisperConfiguration(command: whisperCommand, argumentsTemplate: whisperArguments)
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
        logger.error("Settings persistence failed code=\((error as NSError).code, privacy: .public)")
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

    private static func loadCustomHotkey(from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: Keys.customHotkey) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    static var defaultWhisperCommand: String {
        let candidates = ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "whisper"
    }

    static var defaultWhisperArguments: String {
        "\"{audio}\" --model base --language en --fp16 False --output_format txt --output_dir \"{output}\""
    }

    private enum Keys {
        static let engine = "engine"
        static let model = "model"
        static let language = "language"
        static let hotkey = "hotkey"
        static let customHotkey = "customHotkey"
        static let recordingMode = "recordingMode"
        static let liveTranscription = "liveTranscription"
        static let delivery = "delivery"
        static let playSounds = "playSounds"
        static let allowAppleFallback = "allowAppleFallback"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let showDockIcon = "showDockIcon"
        static let selectedDeviceID = "selectedDeviceID"
        static let selectedInputUID = "selectedInputUID"
        static let whisperCommand = "whisperCommand"
        static let whisperArguments = "whisperArguments"
        static let vocabulary = "vocabulary"
        static let sharedVocabularyURL = "sharedVocabularyURL"
        static let launchAtLogin = "launchAtLogin"
    }
}
