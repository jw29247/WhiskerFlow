import AppKit
import Network
import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

// MARK: - 1. Welcome

struct OnboardingWelcomeStep: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)
            FlowWaveform(size: 60)
            Text("Speak. It’s written.")
                .font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text("Hold one key, say what you mean, and WhiskerFlow types it wherever your cursor is, in any app.")
                .font(.system(size: 15)).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 12) {
                Text(DictationPresentation(appState: appState).gesture)
                FlowKeycap(title: appState.settings.hotkeyDisplayName)
                Text("to dictate")
            }
            .font(.system(size: 18))
            .padding(.vertical, 6)
            OnboardingCard {
                Label("Private by design", systemImage: "lock.shield").font(.system(size: 14, weight: .medium))
                Text("Dictation runs entirely on this Mac. Your voice and your words aren’t sent anywhere. Meeting recording is separate, and stays off unless you turn it on.")
                    .font(.system(size: 13)).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 470)
            Text("Setup takes about two minutes. The speech model is already downloading in the background.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 2. Permissions

struct OnboardingPermissionsStep: View {
    @Bindable var appState: AppState
    @State private var now = Date()

    var body: some View {
        let micGranted = appState.hasMicrophonePermission
        let axGranted = appState.hasAccessibilityPermission
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: "Two permissions.",
                              detail: "WhiskerFlow needs these to hear you and to type for you. This screen updates on its own as you change them.")
            permissionCard(
                title: "Microphone", symbol: "mic", granted: micGranted,
                why: "To hear you while you hold your shortcut. What it hears is transcribed on this Mac.",
                action: micGranted ? nil : (appState.microphonePermission.recoveryAction == .request ? "Allow Microphone" : "Open Microphone Settings"),
                perform: {
                    if appState.microphonePermission.recoveryAction == .request {
                        Task { await appState.requestMicrophonePermission() }
                    } else {
                        SystemSettingsLink.open(SystemSettingsLink.microphone)
                    }
                },
                settingsLink: SystemSettingsLink.microphone
            )
            permissionCard(
                title: "Accessibility", symbol: "keyboard", granted: axGranted,
                why: "To notice your shortcut in any app and paste the text at your cursor. WhiskerFlow doesn’t read what’s on your screen.",
                action: axGranted ? nil : "Allow Accessibility",
                perform: {
                    appState.onboarding.accessibilityRequestedAt = Date()
                    appState.requestAccessibilityPermission()
                    SystemSettingsLink.open(SystemSettingsLink.accessibility)
                },
                settingsLink: SystemSettingsLink.accessibility
            )
            if !axGranted, appState.onboarding.accessibilityRequestedAt != nil {
                Text("In System Settings, switch on WhiskerFlow in the Accessibility list, then come back here.")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
            }
            if OnboardingLaunchPolicy.suggestsAccessibilityRelaunch(
                requestedAt: appState.onboarding.accessibilityRequestedAt, trusted: axGranted, now: now) {
                OnboardingCard {
                    Label("Already switched it on?", systemImage: "arrow.clockwise.circle").font(.system(size: 13, weight: .medium))
                    Text("macOS sometimes applies Accessibility only after WhiskerFlow restarts. Your setup progress is saved and you’ll come straight back here.")
                        .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch WhiskerFlow") { AppRelauncher.relaunch() }
                }
            }
        }
        .task {
            // Re-evaluates the relaunch hint; the permission poll lives in the shell.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private func permissionCard(title: String, symbol: String, granted: Bool, why: String,
                                action: String?, perform: @escaping () -> Void, settingsLink: String) -> some View {
        OnboardingCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 20)).frame(width: 26).foregroundStyle(FlowStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title).font(.system(size: 14, weight: .medium))
                        Spacer()
                        OnboardingStatusBadge(granted: granted)
                    }
                    Text(why).font(.system(size: 12)).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        if let action { Button(action, action: perform) }
                        Button("Open in System Settings") { SystemSettingsLink.open(settingsLink) }
                            .buttonStyle(.plain).foregroundStyle(FlowStyle.accent).font(.caption)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - 3. Microphone

struct OnboardingMicrophoneStep: View {
    @Bindable var appState: AppState
    @State private var probe = OnboardingMicrophoneProbe()
    @State private var check = OnboardingMicrophoneCheck()
    @State private var levels = [Float](repeating: 0, count: 32)
    @State private var startError: String?
    @State private var advice: MicrophoneInputAdvice?
    @State private var deviceName = ""

    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: "Check your microphone.",
                              detail: "Pick the mic you’ll dictate with, then say something, like what you had for breakfast.")
            if !appState.hasMicrophonePermission {
                OnboardingNotice(tone: .warning, text: "Allow the microphone on the previous screen first.")
            }
            OnboardingCard {
                HStack {
                    Text("Microphone").font(.system(size: 13, weight: .medium))
                    Spacer()
                    microphonePicker
                }
                OnboardingLevelBars(levels: levels, threshold: OnboardingMicrophoneCheck.speechLevelThreshold,
                                    heard: check.state == .heardSpeech)
                    .frame(height: 54)
                    .padding(.vertical, 6)
                statusLine
                HStack {
                    if !deviceName.isEmpty {
                        Text("Listening on \(deviceName)").font(.caption).foregroundStyle(FlowStyle.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Test again") { restart() }.disabled(!appState.hasMicrophonePermission)
                }
            }
            if check.signalWarning == .clipping {
                OnboardingNotice(tone: .warning, text: "Your input is so loud it distorts. Lower the input volume in Sound settings or move back a little.")
            }
            if let advice { OnboardingNotice(tone: .warning, text: advice.message) }
            if let startError { OnboardingNotice(tone: .warning, text: startError) }
        }
        .onAppear { restart() }
        .onDisappear { probe.stop() }
        .onChange(of: appState.settings.selectedInputUID) { _, _ in
            appState.onboarding.invalidate(.microphone)
            restart()
        }
        .onChange(of: appState.hasMicrophonePermission) { _, granted in if granted { restart() } }
        .onChange(of: check.state) { _, state in
            if state == .heardSpeech { appState.onboarding.markPassed(.microphone) }
        }
    }

    private var microphonePicker: some View {
        Picker("Microphone", selection: $appState.settings.selectedInputUID) {
            Text("System Default").tag("system-default")
            if appState.settings.selectedInputUID != "system-default",
               !appState.devices.contains(where: { $0.uid == appState.settings.selectedInputUID }) {
                Text("Preferred microphone (disconnected)").tag(appState.settings.selectedInputUID)
            }
            ForEach(appState.devices) { Text($0.name).tag($0.uid) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .disabled(appState.microphoneControlsLocked)
    }

    @ViewBuilder private var statusLine: some View {
        switch check.state {
        case .listening:
            Label("Say something…", systemImage: "waveform").foregroundStyle(FlowStyle.muted).font(.callout)
        case .heardSpeech:
            OnboardingNotice(tone: .success, text: "We heard you. This microphone works.")
        case .tooQuiet:
            VStack(alignment: .leading, spacing: 8) {
                OnboardingNotice(tone: .warning, text: "We can barely hear you. Move closer, speak up, raise the input volume, or pick another microphone, then test again.")
                Button("Open Sound Settings") { SystemSettingsLink.open(SystemSettingsLink.sound) }
            }
        }
    }

    private func restart() {
        probe.stop()
        check.reset()
        levels = [Float](repeating: 0, count: levels.count)
        startError = nil
        let selection = appState.settings.selectedInput
        if let details = CoreAudioDeviceCatalog.inputDetails(for: selection) {
            deviceName = details.name
            advice = MicrophoneInputAdvice.advice(transport: details.transport, name: details.name)
        } else {
            deviceName = ""
            advice = nil
        }
        if UIPreview.isEnabled {
            levels = OnboardingPreview.levels
            check = OnboardingPreview.heardCheck
            return
        }
        guard appState.hasMicrophonePermission else { return }
        probe.onLevel = { level, peak in
            levels.removeFirst()
            levels.append(level)
            check.ingest(level: level, peak: peak, at: ProcessInfo.processInfo.systemUptime)
        }
        // One turn later: building the engine blocks briefly, and the screen
        // should appear first.
        Task { @MainActor in
            await Task.yield()
            do {
                try await probe.start(selection: selection)
            } catch is CancellationError {
            } catch {
                startError = "This microphone couldn’t be opened: \(CaptureErrorPresentation.message(for: error)) Pick another one."
            }
        }
    }
}

struct OnboardingLevelBars: View {
    let levels: [Float]
    let threshold: Float
    let heard: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = CGFloat(levels[index])
                    Capsule()
                        .fill(levels[index] >= threshold ? (heard ? Color.green : FlowStyle.accent) : FlowStyle.accent.opacity(0.35))
                        .frame(height: max(4, level * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityElement()
        .accessibilityLabel(heard ? "Input level: speech detected" : "Input level")
    }
}

// MARK: - 4. Shortcut

struct OnboardingShortcutStep: View {
    @Bindable var appState: AppState
    @State private var monitor: HotkeyMonitor?
    @State private var isPressed = false
    @State private var sawPress = false
    @State private var recordingCustom = false
    @State private var globeUsage = GlobeKeyUsage.current()

    private static let choices: [HotkeyTrigger] = [.fn, .rightCommand, .rightOption, .custom]

    var body: some View {
        let settings = appState.settings
        let passed = appState.onboarding.flow.isSatisfied(.shortcut, appState.onboardingConditions)
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: "Choose your shortcut.",
                              detail: "Pick the key you’ll hold to talk. It works in every app.")
            HStack(spacing: 10) {
                ForEach(Self.choices) { choice in choiceCard(choice, selected: settings.hotkey == choice) }
            }
            if settings.hotkey == .custom {
                KeyRecorderView(combo: $appState.settings.customHotkey,
                                onChange: { appState.reloadHotkey() },
                                onRecordingChange: { recordingCustom = $0 })
                    .frame(maxWidth: 320)
            }
            Picker("Mode", selection: $appState.settings.recordingMode) {
                Text("Hold to talk").tag(RecordingMode.holdToTalk)
                Text("Tap to start/stop").tag(RecordingMode.toggle)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)

            if settings.hotkey == .fn, let explanation = globeUsage.conflictExplanation {
                OnboardingCard {
                    Label("Your 🌐 key already does something", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.system(size: 13, weight: .medium))
                    Text(explanation).font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Settings") { SystemSettingsLink.open(SystemSettingsLink.keyboard) }
                }
            }

            OnboardingCard {
                HStack(spacing: 16) {
                    FlowKeycap(title: settings.hotkeyDisplayName, compact: false)
                        .scaleEffect(isPressed ? 0.94 : 1)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isPressed || passed ? Color.green : .clear, lineWidth: 2))
                        .animation(.easeOut(duration: 0.1), value: isPressed)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(passed ? "Your shortcut works." : (isPressed ? "Got it. Now let go." : "Press your shortcut now."))
                            .font(.system(size: 14, weight: .medium))
                        Text(testDetail(passed: passed)).font(.caption).foregroundStyle(FlowStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if passed { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green) }
                }
            }
        }
        .onAppear {
            // While this screen tests the key, it must not start a real dictation.
            appState.setHotkeyCaptureActive(true)
            startMonitor()
        }
        .onDisappear {
            monitor?.stop()
            monitor = nil
            appState.setHotkeyCaptureActive(false)
        }
        .onChange(of: appState.settings.hotkey) { _, _ in shortcutChanged() }
        .onChange(of: appState.settings.customHotkey) { _, _ in shortcutChanged() }
        .task {
            while !Task.isCancelled {
                let usage = GlobeKeyUsage.current()
                if usage != globeUsage { globeUsage = usage }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func choiceCard(_ choice: HotkeyTrigger, selected: Bool) -> some View {
        Button { appState.settings.hotkey = choice } label: {
            VStack(spacing: 8) {
                Group {
                    switch choice {
                    case .fn: Image(systemName: "globe")
                    case .rightCommand: Text("⌘")
                    case .rightOption: Text("⌥")
                    default: Image(systemName: "keyboard")
                    }
                }
                .font(.system(size: 20, weight: .medium, design: .rounded)).frame(height: 24)
                Text(choice == .fn ? "fn / Globe" : (choice == .custom ? "Custom" : choice.displayName))
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(selected ? FlowStyle.selection : FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? FlowStyle.accent : FlowStyle.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? FlowStyle.accent : FlowStyle.ink)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func testDetail(passed: Bool) -> String {
        let mode = appState.settings.recordingMode == .holdToTalk
            ? "Hold it to talk and let go to paste."
            : "Tap it to start, and tap again to stop and paste."
        if passed && !appState.hasAccessibilityPermission {
            return "It fires here. Allow Accessibility so it also works in other apps."
        }
        return passed ? mode : "Nothing will be recorded. This only checks that WhiskerFlow sees the key."
    }

    private func startMonitor() {
        guard !UIPreview.isEnabled else { return }
        let monitor = HotkeyMonitor(combo: appState.settings.activeHotkeyCombo) { pressed in
            guard !recordingCustom else { return }
            isPressed = pressed
            if pressed {
                sawPress = true
            } else if sawPress {
                appState.onboarding.markPassed(.shortcut)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    private func shortcutChanged() {
        appState.reloadHotkey()
        monitor?.update(combo: appState.settings.activeHotkeyCombo)
        isPressed = false
        sawPress = false
        appState.onboarding.invalidate(.shortcut)
    }
}

// MARK: - 5. Model

@MainActor
@Observable
final class NetworkReachability {
    private(set) var isOnline = true
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil, !UIPreview.isEnabled else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                if self?.isOnline != online { self?.isOnline = online }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

struct OnboardingModelStep: View {
    @Bindable var appState: AppState
    @State private var network = NetworkReachability()

    var body: some View {
        let engine = appState.settings.engine
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: engine == .parakeetTDTv3 ? "Getting your speech model ready." : "Your speech engine.",
                              detail: engine == .parakeetTDTv3
                                ? "WhiskerFlow transcribes on this Mac with Parakeet, a speech model that downloads once. Once it’s ready, your first dictation is instant."
                                : "You’re using \(engine.displayName). It doesn’t need the Parakeet download.")
            OnboardingCard {
                HStack {
                    Label(engine == .parakeetTDTv3 ? "Parakeet TDT v3" : engine.displayName, systemImage: "cpu")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(sizeText).font(.caption).foregroundStyle(FlowStyle.muted)
                }
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(appState.modelState == .ready ? .green : FlowStyle.accent)
                HStack {
                    Text(statusText).font(.callout).foregroundStyle(appState.modelState.isFailure ? .orange : FlowStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if appState.modelState == .preparing, appState.modelDownload.tracker != nil {
                        Text(appState.modelDownload.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit()).foregroundStyle(FlowStyle.muted)
                    }
                    if appState.modelState == .ready {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if appState.modelState.isFailure {
                    Button("Retry") { appState.warmUpEngine() }
                }
            }
            if !network.isOnline && appState.modelState != .ready && appState.modelDownload.needsDownload {
                OnboardingNotice(tone: .warning, text: "You’re offline. The download starts again as soon as you reconnect."
                                 + (appState.settings.allowAppleFallback ? " Until then, dictation uses Apple Speech." : ""))
            } else if appState.modelState.isFailure && appState.settings.allowAppleFallback {
                OnboardingNotice(tone: .info, text: "You can still dictate with Apple Speech while this is sorted out.")
            }
            if appState.modelState != .ready {
                Text("You can keep going. It finishes in the background.").font(.caption).foregroundStyle(FlowStyle.muted)
            }
        }
        .onAppear { network.start() }
        .onDisappear { network.stop() }
        .onChange(of: network.isOnline) { _, online in
            if online && appState.modelState.isFailure { appState.warmUpEngine() }
        }
    }

    private var progressValue: Double {
        switch appState.modelState {
        case .ready: return 1
        case .preparing: return appState.modelDownload.fraction
        case .failed, .unloaded: return appState.modelDownload.fraction
        }
    }

    private var sizeText: String {
        guard appState.settings.engine == .parakeetTDTv3 else { return "No download" }
        let size = ByteCountFormatter.string(fromByteCount: StagedDownloadProgress.parakeetDownloadBytes, countStyle: .file)
        if appState.modelDownload.needsDownload && appState.modelState != .ready { return "About \(size) · one-time download" }
        return "\(size) · stored on this Mac"
    }

    private var statusText: String {
        switch appState.modelState {
        case .ready: return "Ready. Dictation will be instant."
        case .unloaded: return "Waiting to start…"
        case .failed(let message): return message
        case .preparing:
            guard appState.settings.engine == .parakeetTDTv3 else { return "Preparing…" }
            if appState.modelDownload.isCompiling { return "Optimizing for your Mac’s Neural Engine…" }
            return appState.modelDownload.needsDownload ? "Downloading…" : "Loading the model…"
        }
    }
}

// MARK: - 6. Practice

struct OnboardingPracticeStep: View {
    @Bindable var appState: AppState
    @State private var prompt: PracticePrompt = .sample
    @State private var text = ""
    @State private var results: [PracticePrompt: String] = [:]
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: prompt == .sample ? "Try it out." : "Change your mind.",
                              detail: "Click in the box, then \(DictationPresentation(appState: appState).gesture.lowercased()) \(appState.settings.hotkeySpokenName) and read the sentence. \(DictationPresentation(appState: appState).finish) when you’re done.")
            OnboardingCard {
                Text(prompt.instruction).font(.caption).foregroundStyle(FlowStyle.muted)
                Text("“\(prompt.sentence)”").font(.system(size: 18, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 14)).foregroundStyle(FlowStyle.muted)
                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(height: 78)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(fieldFocused ? FlowStyle.accent : FlowStyle.line, lineWidth: 1))

            if let result = results[prompt] {
                outcome(for: prompt, transcript: result)
                if prompt == .sample {
                    Button("Next: change your mind mid-sentence") {
                        prompt = .selfCorrection
                        text = ""
                        fieldFocused = true
                    }
                    .buttonStyle(FlowPrimaryButtonStyle())
                }
            }
            if results[.selfCorrection] != nil {
                OnboardingCard {
                    Label("Now try it anywhere", systemImage: "sparkles").font(.system(size: 13, weight: .medium))
                    Text("Open Notes, Mail or Slack, click where you’d type, and \(DictationPresentation(appState: appState).gesture.lowercased()) \(appState.settings.hotkeySpokenName).")
                        .font(.caption).foregroundStyle(FlowStyle.muted)
                }
            }
        }
        .onAppear {
            appState.practiceDelivery?.practiceField = { insert($0) }
            if UIPreview.isEnabled, let preview = OnboardingPreview.practice {
                prompt = preview.prompt
                results = preview.results
                text = preview.results[preview.prompt] ?? ""
                appState.onboarding.markPassed(.practice)
            }
            fieldFocused = true
        }
        .onDisappear { appState.practiceDelivery?.practiceField = nil }
    }

    private var placeholder: String {
        if appState.isRecording { return "Listening…" }
        if appState.isTranscribing { return "Writing it down…" }
        return "Your words will appear here."
    }

    private func insert(_ transcript: String) {
        text = text.isEmpty ? transcript : text + " " + transcript
        results[prompt] = transcript
        appState.onboarding.markPassed(.practice)
    }

    @ViewBuilder private func outcome(for prompt: PracticePrompt, transcript: String) -> some View {
        switch PracticeEvaluation.evaluate(prompt, transcript: transcript) {
        case .matched:
            OnboardingNotice(tone: .success, text: "Nicely done. That’s what you said, typed for you.")
        case .corrected:
            OnboardingNotice(tone: .success, text: "WhiskerFlow kept only what you meant: “\(transcript)”")
        case .notCorrected:
            OnboardingNotice(tone: .warning, text: "The correction stayed in. Turn on “Recognize clear spoken corrections” in Assistant to have WhiskerFlow tidy these up.")
        case .different:
            OnboardingNotice(tone: .info, text: "That’s what WhiskerFlow heard. Try the sentence again if you like.")
        }
    }
}

// MARK: - 7. Extras

struct OnboardingExtrasStep: View {
    @Bindable var appState: AppState
    @State private var screenRecordingRequestedAt: Date?

    var body: some View {
        let paired = appState.isAtlasPaired
        let assistant = appState.assistant
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: "Optional extras.",
                              detail: "Skip these now if you like. They live in Meetings, Assistant and Settings.")
            OnboardingCard {
                HStack {
                    Label("Connect Atlas", systemImage: "person.crop.circle.badge.checkmark").font(.system(size: 14, weight: .medium))
                    Spacer()
                    if paired {
                        OnboardingStatusBadge(granted: true, grantedText: "Connected")
                    } else {
                        Button(appState.isSigningInToAtlas ? "Connecting…" : "Connect") { appState.signInToAtlas() }
                            .disabled(appState.isSigningInToAtlas)
                    }
                }
                Text("Your agency workspace. Connecting unlocks meeting recordings and transcripts, the Assistant, and each client’s vocabulary, so names and jargon come out right.")
                    .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                if let error = appState.atlasSignInError { Text(error).font(.caption).foregroundStyle(.orange) }
                if paired {
                    HStack {
                        Picker("Active client", selection: Binding(get: { assistant.saved.selectedClient ?? "" }, set: { reference in
                            assistant.selectClient(reference.isEmpty ? nil : reference)
                            Task { await assistant.refreshSelectedVocabulary() }
                        })) {
                            Text("No client").tag("")
                            ForEach(assistant.saved.clients) { Text($0.name).tag($0.reference) }
                        }
                        .disabled(assistant.busy)
                        Button("Refresh") { Task { await assistant.refreshClients() } }.disabled(assistant.busy)
                    }
                }
            }
            OnboardingCard {
                HStack {
                    Label("Meeting recording", systemImage: "person.2.wave.2").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Toggle("Record scheduled meetings automatically", isOn: $appState.settings.meetingModeEnabled)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!paired)
                        .onChange(of: appState.settings.meetingModeEnabled) { _, _ in appState.refreshMeetingConfiguration() }
                }
                Text(paired
                     ? "Records eligible calendar meetings and saves the recording and transcript to Atlas."
                     : "Connect Atlas first. Meetings are saved to your Atlas workspace.")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
                Divider()
                HStack {
                    Text("Screen Recording").font(.system(size: 13))
                    Spacer()
                    OnboardingStatusBadge(granted: appState.hasScreenRecordingPermission)
                    if !appState.hasScreenRecordingPermission {
                        Button("Allow") {
                            screenRecordingRequestedAt = Date()
                            appState.requestScreenRecordingPermission()
                            SystemSettingsLink.open(SystemSettingsLink.screenRecording)
                        }
                    }
                }
                Text("macOS calls meeting audio access Screen Recording. WhiskerFlow uses it to capture the meeting’s sound and see who’s speaking. Screen images are never saved or uploaded.")
                    .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
                if screenRecordingRequestedAt != nil && !appState.hasScreenRecordingPermission {
                    HStack {
                        Text("macOS applies this after WhiskerFlow restarts.").font(.caption).foregroundStyle(FlowStyle.muted)
                        Spacer()
                        Button("Relaunch WhiskerFlow") { AppRelauncher.relaunch() }
                    }
                }
            }
        }
        .task(id: paired) {
            if paired && assistant.saved.clients.isEmpty && !UIPreview.isEnabled { await assistant.refreshClients() }
        }
    }
}

// MARK: - 8. Done

struct OnboardingDoneStep: View {
    let appState: AppState

    var body: some View {
        let presentation = DictationPresentation(appState: appState)
        VStack(spacing: 12) {
            OnboardingHeading(symbol: "checkmark.seal", title: "You’re all set.",
                              detail: "Here’s everything you can do from the keyboard.")
            OnboardingCard {
                shortcutRow(keys: appState.settings.hotkeyDisplayName, action: "Dictate", detail: presentation.gesture == "Hold" ? "Hold, speak, let go" : "Tap to start, tap to stop")
                Divider()
                shortcutRow(keys: "⌥⇧⌘E", action: "Voice edit a selection", detail: "Hold and say how to change it")
                shortcutRow(keys: "⌥⇧⌘N", action: "Quick voice capture", detail: "Hold to save a note")
                shortcutRow(keys: "⌥⇧⌘R", action: "Start or stop meeting recording", detail: "Press")
                shortcutRow(keys: "⌥⇧⌘B", action: "Bookmark the meeting", detail: "Press while recording")
                Divider()
                shortcutRow(keys: "⌘1 – ⌘5", action: "Switch screens", detail: "In the WhiskerFlow window")
            }
            Text("Change your dictation shortcut in Settings → Dictation. The ⌥⇧⌘ shortcuts are fixed. You can run this setup again from Help → Run Setup Again, the menu bar, or Settings → App.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
    }

    private func shortcutRow(keys: String, action: String, detail: String) -> some View {
        HStack(spacing: 14) {
            FlowKeycap(title: keys, compact: true).frame(minWidth: 96, alignment: .leading)
            Text(action).font(.system(size: 13))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(FlowStyle.muted)
        }
    }
}

// MARK: - Visual QA fixtures

/// Static content for `--ui-preview`, which never opens the microphone.
@MainActor
enum OnboardingPreview {
    static let levels: [Float] = (0..<32).map { index in
        let wave = sin(Double(index) * 0.55) * 0.5 + 0.5
        return Float(0.12 + wave * (index > 12 ? 0.55 : 0.1))
    }

    static var heardCheck: OnboardingMicrophoneCheck {
        var check = OnboardingMicrophoneCheck()
        var time: TimeInterval = 0
        while time < 1 {
            check.ingest(level: 0.6, peak: 0.4, at: time)
            time += 0.1
        }
        return check
    }

    static var practice: (prompt: PracticePrompt, results: [PracticePrompt: String])? {
        guard UIPreview.mode == "onboarding-practice" else { return nil }
        return (.selfCorrection, [
            .sample: "WhiskerFlow turns what I say into text, right where my cursor is.",
            .selfCorrection: "Let’s meet at 3."
        ])
    }
}
