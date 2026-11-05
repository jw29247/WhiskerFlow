import SwiftUI
import WhiskerFlowCore

struct CleanupSettingsView: View {
    @Bindable var appState: AppState
    @State private var sample = "I want to do that on Wednesday, no, Thursday at 8 p.m., no, 10 PM."
    @State private var result: CleanupResult?
    @State private var testing = false

    private let model = CleanupModel.gemma4E2B

    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle("Clean up dictation", isOn: $appState.settings.cleanupEnabled)
                    .disabled(!CleanupService.supported || (!appState.cleanup.installed(model) && !appState.settings.cleanupEnabled))
                Text("Corrects recognition mistakes, spelling and grammar into British English, removes hesitations and resolves spoken self-corrections while keeping your meaning. Runs entirely on this Mac after transcription. The original stays in History when history is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cleanup is a preview. Check names, numbers and corrections before sending important text. Literal writing style and voice editing instructions skip Cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Transcripts over 4,000 characters use normal transcription in this preview.")
                    .font(.caption).foregroundStyle(.secondary)
                if !CleanupService.supported {
                    Text("Cleanup needs an Apple silicon Mac with at least 8 GB of memory.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Learning") {
                Text("Edits to pasted dictation and History are checked by the same local model in the background. Recognition fixes are saved to Corrections automatically. Rewording and style changes aren't learned. Dictation takes priority over learning.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Local model") {
                Text("Gemma 4 E2B uses 4-bit weights and needs at least 8 GB of memory. Cleanup checks available memory and pauses if your Mac is short of resources. Macs with less than 16 GB release it sooner between dictations.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Selected", value: model.name)
                LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                LabeledContent("Status", value: appState.cleanup.status)
                LabeledContent("Last transcript", value: appState.cleanup.lastRun)
                if appState.cleanup.downloading {
                    ProgressView(value: appState.cleanup.downloadProgress)
                    Button("Cancel download") { appState.cleanup.cancelDownload() }
                } else if !appState.cleanup.installed(model) {
                    Text("The model is provided under the Apache 2.0 licence and downloads from Hugging Face. Cleanup processes your text on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Model licence", destination: URL(string: "https://huggingface.co/google/gemma-4-E2B-it/blob/main/LICENSE")!)
                        Link("About Gemma 4", destination: URL(string: "https://huggingface.co/google/gemma-4-E2B-it")!)
                    }
                    Button("Download \(model.name)") {
                        appState.cleanup.download(model) {
                            appState.settings.cleanupEnabled = true
                            appState.configureCleanup()
                        }
                    }.disabled(!CleanupService.supported)
                } else {
                    Button("Download model again") { appState.cleanup.download(model) {} }
                        .disabled(appState.cleanup.running)
                }
                Text("Warms up when Cleanup is enabled and when you start dictating, then sleeps after \(Int(model.idleSeconds)) seconds without use. Releases idle model memory sooner when your Mac is busy. If Cleanup is unavailable or takes too long, dictation uses the original transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Release model memory now") { appState.cleanup.sleepNow() }
                    .disabled(appState.cleanup.running)
            }

            Section("Try Cleanup") {
                TextEditor(text: $sample).font(.body).frame(minHeight: 75)
                    .accessibilityLabel("Transcript to clean up")
                Button(testing ? "Cleaning up…" : "Clean up this text") {
                    testing = true
                    appState.automaticCorrections.setBusy(true)
                    let input = sample
                    let selected = model
                    let vocabulary = appState.effectiveVocabulary
                    Task { @MainActor in
                        result = await appState.cleanup.clean(input, model: selected, vocabulary: vocabulary)
                        testing = false
                        appState.automaticCorrections.setBusy(appState.isRecording || appState.isTranscribing)
                    }
                }.disabled(testing || appState.isRecording || appState.isTranscribing || appState.cleanup.running || !appState.settings.cleanupEnabled
                    || !appState.cleanup.installed(model) || sample.isEmpty)
                if let result {
                    Text(result.text).textSelection(.enabled)
                    Text(result.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
