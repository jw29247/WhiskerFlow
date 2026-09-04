import SwiftUI
import WhiskerFlowCore

struct TranscriptDetailView: View {
    @Bindable var appState: AppState
    let record: TranscriptRecord
    @Binding var draft: TranscriptDraft
    var saveDraft: () -> Bool
    @State private var confirmDelete = false
    @State private var saveError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.createdAt, format: .dateTime.month(.wide).day())
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text(record.createdAt, format: .dateTime.weekday(.wide).hour().minute())
                        .font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                }
                Spacer(minLength: 8)
                FlowCopyButton(text: record.status == .transcribed ? draft.text : record.text, allowsEmpty: record.status == .transcribed, copy: appState.copyEditorText)
                    .buttonStyle(FlowPrimaryButtonStyle())
                Menu {
                    Button("Delete recording…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.top, 10)
                    .help("Transcript actions")
            }.padding(.bottom, 22)

            if !appState.records.contains(where: { $0.id == record.id }) {
                Text("The original recording was removed from history. Save to keep your text as a new transcript.")
                    .font(.caption).foregroundStyle(FlowStyle.muted).padding(.bottom, 12)
            }
            if record.status == .transcribed {
                TextEditor(text: $draft.text)
                    .font(.system(size: 16))
                    .lineSpacing(7)
                    .scrollContentBackground(.hidden)
                    .padding(13)
                    .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line.opacity(0.6), lineWidth: 1))
                    .accessibilityLabel("Transcript text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if draft.isDirty {
                    HStack {
                        Text("Unsaved changes").font(.caption).foregroundStyle(FlowStyle.muted)
                        Spacer()
                        Button("Discard") { draft.discard() }
                        Button("Save changes", action: save)
                            .buttonStyle(FlowPrimaryButtonStyle())
                            .keyboardShortcut("s", modifiers: .command)
                    }.padding(.top, 14)
                }
                vocabularySuggestions
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label(record.status.isFailed ? "Transcription needs another try" : "Working on your words…",
                          systemImage: record.status.isFailed ? "exclamationmark.circle" : "waveform")
                        .font(.headline)
                    if case .failed(let message) = record.status {
                        Text(message).font(.callout).foregroundStyle(FlowStyle.muted).textSelection(.enabled)
                        Button("Retry transcription") { appState.retry(record) }
                            .buttonStyle(FlowPrimaryButtonStyle())
                    } else { ProgressView().controlSize(.small) }
                    if !record.text.isEmpty { Text(record.text).textSelection(.enabled) }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
                    if let duration = record.durationSeconds {
                        Text("Recording length: \(Int(duration) / 60):\(String(format: "%02d", Int(duration) % 60))")
                    }
                    if let engine = record.engine { Text("Engine: \(TranscriptionEngineKind(rawValue: engine)?.displayName ?? engine)") }
                    if let language = record.language { Text("Language: \(language)") }
                }.font(.caption).foregroundStyle(FlowStyle.muted).padding(.top, 8)
            } label: {
                Text("\(record.wordCount) words · Recording details").font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
            }.padding(.top, 18)
        }
        .padding(26)
        .alert("Delete this recording?", isPresented: $confirmDelete) {
            Button("Delete recording", role: .destructive) {
                appState.delete(record)
                if !appState.records.contains(where: { $0.id == record.id }) { draft = TranscriptDraft() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(draft.isDirty
                 ? "The recording, transcript and your unsaved changes will be permanently deleted."
                 : "The recording and transcript will be permanently deleted.")
        }
        .alert("Changes couldn’t be saved", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Your edits are still here. Please try again before leaving this transcript.") }
    }

    @ViewBuilder
    private var vocabularySuggestions: some View {
        if !appState.pendingVocabularySuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(appState.pendingVocabularySuggestions, id: \.self) { suggestion in
                    HStack {
                        Text("Always replace “\(suggestion.find)” with “\(suggestion.replaceWith)”? ")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Add") { appState.acceptVocabularySuggestion(suggestion) }
                    }
                }
                Button("Dismiss") { appState.dismissVocabularySuggestions() }.font(.caption)
            }.padding(12).background(FlowStyle.selection, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 12)
        }
    }

    private func save() {
        if !saveDraft() { saveError = true }
    }
}
