import AppKit
import SwiftUI
import WhiskerFlowCore

struct AssistantView: View {
    @Bindable var appState: AppState
    @State private var tab = 0
    @State private var operation = "shorten"
    @State private var typedCapture = ""
    @State private var appIdentifier = ""
    @State private var style: WritingStyle = .standard
    @State private var captureCountdown = false
    @State private var clientFind = ""
    @State private var clientReplacement = ""
    private var assistant: AssistantController { appState.assistant }
    private var unavailable: Bool { assistant.busy || appState.isRecording || appState.isTranscribing || appState.isMeetingCapturing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Assistant").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Shape your words, save an idea, or make dictation feel at home in each app.")
                    .foregroundStyle(FlowStyle.muted)
                Picker("Assistant tool", selection: $tab) {
                    Text("Edit selection").tag(0)
                    Text("Quick capture").tag(1)
                    Text("Writing preferences").tag(2)
                }.pickerStyle(.segmented)
                if let message = assistant.message {
                    HStack {
                        Text(message).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { assistant.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel("Dismiss assistant message")
                    }.padding(14).background(FlowStyle.selection, in: RoundedRectangle(cornerRadius: 10))
                }
                if assistant.busy {
                    HStack {
                        ProgressView("Working…").controlSize(.small)
                        if assistant.saved.pendingJob != nil { Button("Stop waiting") { assistant.pauseWaiting() } }
                    }
                }
                if assistant.saved.pendingJob != nil {
                    HStack {
                        Text("A request is waiting for its result.")
                        Spacer()
                        Button("Resume") { Task { await assistant.resumeJob() } }.disabled(unavailable)
                        Button("Discard request") { assistant.discardPendingJob() }.disabled(assistant.busy)
                    }.font(.callout)
                }
                Group {
                    switch tab {
                    case 0: selectionEditor
                    case 1: quickCapture
                    default: preferences
                    }
                }
            }.padding(32).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var selectionEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("1. Select text in another app").font(.headline)
            Text("Select text and hold ⌥⇧⌘E while speaking your instruction. Or choose “Use voice instruction” and use your usual shortcut after returning to your text.")
                .font(.callout).foregroundStyle(FlowStyle.muted)
            HStack {
                Button(assistant.capturePurpose == .selectionInstruction ? "Voice instruction armed" : "Use voice instruction") {
                    assistant.capturePurpose = .selectionInstruction
                }.disabled(unavailable)
                Button(captureCountdown ? "Switch to your text…" : "Capture in 3 seconds") {
                    captureCountdown = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        assistant.captureSelection()
                        captureCountdown = false
                    }
                }.disabled(captureCountdown || unavailable)
                if assistant.capturePurpose == .selectionInstruction {
                    Button("Cancel") { assistant.capturePurpose = .dictation }
                }
            }
            if !assistant.rewriteInput.isEmpty {
                Text("Original selection").font(.caption).foregroundStyle(FlowStyle.muted)
                Text(assistant.rewriteInput).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                Text("2. Choose an edit").font(.headline)
                Picker("Edit", selection: $operation) {
                    Text("Shorten").tag("shorten")
                    Text("Professional").tag("professional")
                    Text("Friendly").tag("friendly")
                    Text("Bullet points").tag("bullet_points")
                    Text("My instruction").tag("custom")
                }.disabled(unavailable)
                if operation == "custom" {
                    TextField("What should change?", text: $appState.assistantVoiceInstruction, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(unavailable)
                }
                cloudConsent
                Button("Generate preview") {
                    Task { await assistant.rewrite(operation: operation, instruction: appState.assistantVoiceInstruction) }
                }.buttonStyle(FlowPrimaryButtonStyle()).disabled(unavailable || !assistant.saved.cloudEnabled)
            }
            if !assistant.rewritePreview.isEmpty {
                Text("3. Review before replacing").font(.headline)
                Text(assistant.rewritePreview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(FlowStyle.selection, in: RoundedRectangle(cornerRadius: 10))
                Text("Check names, dates and meaning. The original document must still match before Replace can proceed.")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
                HStack {
                    Button("Replace selection") { Task { await appState.replaceAssistantSelection() } }
                        .buttonStyle(FlowPrimaryButtonStyle()).disabled(unavailable || assistant.selection == nil)
                    Button("Copy preview") { appState.copy(assistant.rewritePreview) }
                    Button("Cancel") { assistant.clearSelection() }.disabled(assistant.busy)
                }
            }
        }.onChange(of: appState.assistantVoiceInstruction) { _, value in if !value.isEmpty { operation = "custom" } }
    }

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("An idea now. A useful draft later.").font(.headline)
            Picker("Save as", selection: Binding(get: { assistant.quickCaptureKind }, set: { assistant.quickCaptureKind = $0 })) {
                Text("Note").tag(AssistantRecordKind.note)
                Text("Task draft").tag(AssistantRecordKind.taskDraft)
                Text("Client update draft").tag(AssistantRecordKind.clientUpdateDraft)
            }.pickerStyle(.segmented)
            clientPicker
            HStack {
                Button(assistant.capturePurpose == .quickCapture ? "Voice capture armed" : "Capture by voice") { assistant.capturePurpose = .quickCapture }
                    .disabled(unavailable)
                Text("Use \(appState.settings.hotkeyDisplayName) for the next recording, or hold ⌥⇧⌘N any time to capture a draft.")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
                if assistant.capturePurpose == .quickCapture { Button("Cancel") { assistant.capturePurpose = .dictation } }
            }
            TextField("Or write a quick thought…", text: $typedCapture, axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder)
            Button("Save on this Mac") {
                if assistant.saveLocalDraft(typedCapture, kind: assistant.quickCaptureKind) != nil { typedCapture = "" }
            }.disabled(typedCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Text("Your drafts").font(.headline)
            if assistant.saved.drafts.isEmpty {
                Text("Nothing captured yet. Drafts stay here until you choose to save them to Atlas.").foregroundStyle(FlowStyle.muted)
            }
            ForEach(assistant.saved.drafts) { draft in
                AssistantDraftRow(draft: draft, busy: assistant.busy, paired: appState.isAtlasPaired,
                    save: { title, text in assistant.editDraft(draft.id, title: title, text: text) },
                    send: { Task { await assistant.sendDraft(draft.id) } },
                    copy: { appState.copy(draft.text) }, remove: { assistant.deleteLocalDraft(draft.id) })
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Recognize clear spoken corrections", isOn: Binding(get: { assistant.saved.recognizeCorrections }, set: { assistant.setRecognizeCorrections($0) }))
            Text("For example, “Send it to Mark, sorry, Marc.” Ambiguous repairs stay as spoken. Original recognition remains in History.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
            Divider()
            Text("Client vocabulary").font(.headline)
            clientPicker
            Text("Only the selected client's vocabulary is used. Your personal correction rules take priority.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
            if let client = assistant.saved.selectedClient {
                if let refreshed = assistant.saved.clientUpdatedAt?[client] {
                    Text("Cached on this Mac · refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(FlowStyle.muted)
                } else {
                    Text("Refresh to cache this client's vocabulary for offline use.").font(.caption).foregroundStyle(FlowStyle.muted)
                }
                HStack {
                    TextField("Recognized word", text: $clientFind).textFieldStyle(.roundedBorder)
                    TextField("Use instead", text: $clientReplacement).textFieldStyle(.roundedBorder)
                    Button("Add client term") {
                        assistant.addClientTerm(find: clientFind, replacement: clientReplacement)
                        clientFind = ""; clientReplacement = ""
                    }.disabled(clientFind.isEmpty || clientReplacement.isEmpty)
                }
                ForEach(assistant.saved.clientCustomVocabulary?[client]?.rules ?? []) { rule in
                    HStack {
                        Text("\(rule.find) → \(rule.replaceWith)")
                        Spacer()
                        Button("Remove") { assistant.removeClientTerm(rule.id) }
                    }.font(.caption)
                }
            }
            Divider()
            Text("App writing profiles").font(.headline)
            Text("Standard uses your existing formatting. Conversational removes fillers and supports line commands. Polished also capitalizes sentences. Literal keeps the recognized words.")
                .font(.callout).foregroundStyle(FlowStyle.muted)
            Picker("Application", selection: $appIdentifier) {
                Text("Choose an open app").tag("")
                ForEach(runningApps, id: \.bundleIdentifier) { app in
                    Text(app.localizedName ?? app.bundleIdentifier ?? "App").tag(app.bundleIdentifier ?? "")
                }
            }
            Picker("Writing style", selection: $style) {
                ForEach(WritingStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Button("Save app profile") { assistant.setProfile(bundleIdentifier: appIdentifier, style: style) }.disabled(appIdentifier.isEmpty)
            ForEach(assistant.saved.profiles, id: \.bundleIdentifier) { profile in
                HStack {
                    Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier)?.deletingPathExtension().lastPathComponent ?? profile.bundleIdentifier)
                    Spacer(); Text(profile.style.rawValue.capitalized).foregroundStyle(FlowStyle.muted)
                    Button("Reset") { assistant.setProfile(bundleIdentifier: profile.bundleIdentifier, style: .standard) }
                }.font(.callout)
            }
            Divider()
            cloudConsent
        }.onChange(of: appIdentifier) { _, value in style = assistant.style(for: value) }
    }
    private var runningApps: [NSRunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier && app.bundleIdentifier.map { seen.insert($0).inserted } == true
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    private var clientPicker: some View {
        HStack {
            Picker("Client", selection: Binding(get: { assistant.saved.selectedClient ?? "" }, set: { reference in
                assistant.selectClient(reference.isEmpty ? nil : reference)
                Task { await assistant.refreshSelectedVocabulary() }
            })) {
                Text("No client").tag("")
                ForEach(assistant.saved.clients) { Text($0.name).tag($0.reference) }
            }.disabled(assistant.busy)
            Button("Refresh clients") { Task { await assistant.refreshClients() } }.disabled(assistant.busy || !appState.isAtlasPaired)
        }
    }
    private var cloudConsent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Use Atlas AI when I request it", isOn: Binding(get: { assistant.saved.cloudEnabled }, set: { assistant.setCloudEnabled($0) }))
                .disabled(assistant.busy)
            Text("When enabled, selection edits send the selected text and instruction to Atlas and its AI provider. Preparation sends your goal and agenda; reviews use your saved meeting transcript. Live prompts stay on this Mac.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
        }
    }
}
