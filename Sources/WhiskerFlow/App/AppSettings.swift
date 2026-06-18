import Foundation
import Observation
import ServiceManagement
import WhiskerFlowCore

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var engine: TranscriptionEngineKind { didSet { persist() } }
    var model: WhisperModel { didSet { persist() } }
    /// BCP-47 code, or "auto" to let the engine detect.
    var language: String { didSet { persist() } }
    var hotkey: HotkeyTrigger { didSet { persist() } }
    var recordingMode: RecordingMode { didSet { persist() } }
    /// Stream and transcribe while speaking so the transcript pastes instantly on
    /// release. Applies to the WhisperKit engine; other engines stay file-based.
    var liveTranscription: Bool { didSet { persist() } }
    var delivery: DeliveryMode { didSet { persist() } }
    var playSounds: Bool { didSet { persist() } }
    var allowAppleFallback: Bool { didSet { persist() } }
    var showMenuBarExtra: Bool { didSet { persist() } }
    var showDockIcon: Bool { didSet { persist() } }
    var selectedDeviceID: String { didSet { persist() } }
    var whisperCommand: String { didSet { persist() } }
    var whisperArguments: String { didSet { persist() } }
    var vocabulary: Vocabulary { didSet { persist() } }

    var launchAtLogin: Bool {
        didSet {
            persist()
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        engine = defaults.string(forKey: Keys.engine).flatMap(TranscriptionEngineKind.init) ?? .whisperKit
        model = defaults.string(forKey: Keys.model).flatMap(WhisperModel.init) ?? .tiny
        language = defaults.string(forKey: Keys.language) ?? "en"
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyTrigger.init) ?? .fn
        recordingMode = defaults.string(forKey: Keys.recordingMode).flatMap(RecordingMode.init) ?? .holdToTalk
        liveTranscription = defaults.object(forKey: Keys.liveTranscription) as? Bool ?? true
        delivery = defaults.string(forKey: Keys.delivery).flatMap(DeliveryMode.init) ?? .pasteAtCursor
        playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
        allowAppleFallback = defaults.object(forKey: Keys.allowAppleFallback) as? Bool ?? true
        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        selectedDeviceID = defaults.string(forKey: Keys.selectedDeviceID) ?? ""
        whisperCommand = defaults.string(forKey: Keys.whisperCommand) ?? Self.defaultWhisperCommand
        whisperArguments = defaults.string(forKey: Keys.whisperArguments) ?? Self.defaultWhisperArguments
        vocabulary = Self.loadVocabulary(from: defaults) ?? Vocabulary()
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    var resolvedLanguage: String? {
        language.lowercased() == "auto" ? nil : language
    }

    var cliConfiguration: WhisperConfiguration {
        WhisperConfiguration(command: whisperCommand, argumentsTemplate: whisperArguments)
    }

    private func persist() {
        defaults.set(engine.rawValue, forKey: Keys.engine)
        defaults.set(model.rawValue, forKey: Keys.model)
        defaults.set(language, forKey: Keys.language)
        defaults.set(hotkey.rawValue, forKey: Keys.hotkey)
        defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode)
        defaults.set(liveTranscription, forKey: Keys.liveTranscription)
        defaults.set(delivery.rawValue, forKey: Keys.delivery)
        defaults.set(playSounds, forKey: Keys.playSounds)
        defaults.set(allowAppleFallback, forKey: Keys.allowAppleFallback)
        defaults.set(showMenuBarExtra, forKey: Keys.showMenuBarExtra)
        defaults.set(showDockIcon, forKey: Keys.showDockIcon)
        defaults.set(selectedDeviceID, forKey: Keys.selectedDeviceID)
        defaults.set(whisperCommand, forKey: Keys.whisperCommand)
        defaults.set(whisperArguments, forKey: Keys.whisperArguments)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        if let data = try? JSONEncoder().encode(vocabulary) {
            defaults.set(data, forKey: Keys.vocabulary)
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
            // Non-fatal — surfaced indirectly; the toggle simply won't stick.
        }
    }

    private static func loadVocabulary(from defaults: UserDefaults) -> Vocabulary? {
        guard let data = defaults.data(forKey: Keys.vocabulary) else { return nil }
        return try? JSONDecoder().decode(Vocabulary.self, from: data)
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
        static let recordingMode = "recordingMode"
        static let liveTranscription = "liveTranscription"
        static let delivery = "delivery"
        static let playSounds = "playSounds"
        static let allowAppleFallback = "allowAppleFallback"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let showDockIcon = "showDockIcon"
        static let selectedDeviceID = "selectedDeviceID"
        static let whisperCommand = "whisperCommand"
        static let whisperArguments = "whisperArguments"
        static let vocabulary = "vocabulary"
        static let launchAtLogin = "launchAtLogin"
    }
}
