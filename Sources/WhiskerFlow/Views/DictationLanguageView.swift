import SwiftUI
import Translation
import WhiskerFlowAppSupport

/// "Which language will you speak?" plus "write it in English", with what
/// each needs on this Mac. Shared by Settings and setup.
struct DictationLanguageControls: View {
    @Bindable var appState: AppState
    @State private var translation: DictationTranslator.Readiness?
    @State private var downloadRequest: AnyHashable?

    private var settings: AppSettings { appState.settings }
    private var plan: DictationLanguagePlan { settings.languagePlan }
    private var languageName: String {
        Locale(identifier: "en").localizedString(forIdentifier: plan.language) ?? plan.language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("I speak", selection: Binding(get: { plan.language }, set: { settings.language = $0 })) {
                ForEach(DictationLanguageCatalog.options) { Text($0.displayName).tag($0.code) }
            }
            .onChange(of: settings.language) { _, _ in appState.warmUpEngine() }
            if plan.language != "en" {
                Toggle("Write it in English", isOn: Binding(get: { settings.translateToEnglish },
                                                           set: { settings.translateToEnglish = $0 }))
                Text(settings.translateToEnglish
                     ? "Speak \(plan.language == "auto" ? "any language" : languageName) and WhiskerFlow types it in English, translated on this Mac by Apple. Anything you say in English is left as it is."
                     : "WhiskerFlow types what you say, in the language you say it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                speechStatus
                if settings.translateToEnglish { translationStatus }
            }
        }
        .task(id: "\(plan.language)|\(settings.translateToEnglish)") { await refreshTranslation() }
        .modifier(TranslationDownloader(request: $downloadRequest, language: plan.language) {
            Task { await refreshTranslation() }
        })
    }

    @ViewBuilder private var speechStatus: some View {
        switch plan.route {
        case .parakeet:
            status("checkmark.circle", "Speech: Parakeet, on this Mac", ok: true)
        case .appleDictation:
            switch appState.languageModelState {
            case .ready: status("checkmark.circle", "Speech: Apple's dictation model, on this Mac", ok: true)
            case .downloading: status("arrow.down.circle", "Speech: downloading Apple's \(languageName) model…", ok: nil)
            case .unavailable:
                HStack {
                    status("exclamationmark.triangle", "Speech: Apple's \(languageName) model needs macOS 26 and a connection to download.", ok: false)
                    Button("Try again") { appState.prepareDictationLanguage() }
                }
            case .notNeeded: EmptyView()
            }
        }
    }

    @ViewBuilder private var translationStatus: some View {
        if plan.language == "auto" {
            status("info.circle", "Translation: each language's model downloads the first time you need it, in Settings.", ok: nil)
        } else {
            switch translation {
            case .ready?: status("checkmark.circle", "Translation into English: ready", ok: true)
            case .needsDownload?:
                HStack {
                    status("arrow.down.circle", "Translation into English: needs a one-time download", ok: nil)
                    Button("Download") { downloadRequest = AnyHashable(UUID()) }
                }
            case .unsupported?:
                status("exclamationmark.triangle", "Apple can't translate \(languageName) into English on this Mac yet, so it will be typed as you say it.", ok: false)
            case nil: ProgressView().controlSize(.small)
            }
        }
    }

    private func status(_ symbol: String, _ text: String, ok: Bool?) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshTranslation() async {
        guard plan.translationSource != nil, plan.language != "auto" else { translation = nil; return }
        translation = await DictationTranslator.readiness(from: plan.language)
    }
}

/// Asks macOS to download a translation language. The download needs the
/// system's own confirmation sheet, which only a SwiftUI view can present.
private struct TranslationDownloader: ViewModifier {
    @Binding var request: AnyHashable?
    let language: String
    let finished: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.translationTask(configuration) { session in
                try? await session.prepareTranslation()
                request = nil
                finished()
            }
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private var configuration: TranslationSession.Configuration? {
        guard request != nil else { return nil }
        return TranslationSession.Configuration(source: DictationTranslator.translationLanguage(for: language),
                                                target: DictationTranslator.english)
    }
}
