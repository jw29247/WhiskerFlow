import AppKit
import Network
import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

// MARK: - 1. Permissions

struct OnboardingPermissionsStep: View {
    @Bindable var appState: AppState
    @State private var now = Date()

    var body: some View {
        let micGranted = appState.hasMicrophonePermission
        let axGranted = appState.hasAccessibilityPermission
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: "Welcome to WhiskerFlow.",
                              detail: "Hold a key, speak, and it types for you in any app. First, allow these two so it can hear you and type. This screen updates as you go.")
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
                    Label("Already switched it on?", systemImage: "arrow.clockwise.circle").font(FlowStyle.callout.weight(.medium))
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
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title).font(FlowStyle.body.weight(.medium))
                        Spacer()
                        OnboardingStatusBadge(granted: granted)
                    }
                    Text(why).font(FlowStyle.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
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

// MARK: - 2. Microphone

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
                    Text("Microphone").font(FlowStyle.callout.weight(.medium))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = CGFloat(levels[index])
                    Capsule()
                        .fill(levels[index] >= threshold ? (heard ? FlowStyle.success : FlowStyle.accent) : FlowStyle.accent.opacity(0.35))
                        .frame(height: max(4, level * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: levels)
        .accessibilityElement()
        .accessibilityLabel(heard ? "Input level: speech detected" : "Input level")
    }
}

// MARK: - Network

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

// MARK: - 3. Practice

struct OnboardingPracticeStep: View {
    @Bindable var appState: AppState
    let model: OnboardingModelWatch
    @State private var prompt: PracticePrompt = .sample
    @State private var text = ""
    @State private var results: [PracticePrompt: String] = [:]
    @FocusState private var fieldFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let presentation = DictationPresentation(appState: appState)
        let readiness = OnboardingPracticeReadiness(phase: model.phase(of: appState),
                                                    fallbackAllowed: appState.settings.allowAppleFallback)
        VStack(spacing: 12) {
            OnboardingHeading(symbol: nil, title: prompt == .sample ? "Try it out." : "Change your mind.",
                              detail: "Click in the box, \(presentation.gesture.lowercased()) \(appState.settings.hotkeySpokenName) and read the sentence aloud. \(presentation.finish) when you’re done.")
            shortcutCard
            if readiness.headline != nil { modelCard(readiness) }
            OnboardingCard {
                Text(prompt.instruction).font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
                Text("“\(prompt.sentence)”").font(FlowStyle.subheading.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(FlowStyle.body)
                    .focused($fieldFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .disabled(!readiness.canPractise)
                    .accessibilityLabel("Practice box")
                if text.isEmpty {
                    Text(placeholder(readiness)).font(FlowStyle.body).foregroundStyle(FlowStyle.muted)
                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 78)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(fieldFocused ? FlowStyle.accent : FlowStyle.line, lineWidth: 1))
            .opacity(readiness.canPractise ? 1 : 0.6)

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
        }
        .onAppear {
            appState.practiceDelivery?.practiceField = { insert($0) }
            if UIPreview.isEnabled, let preview = OnboardingPreview.practice {
                prompt = preview.prompt
                results = preview.results
                text = preview.results[preview.prompt] ?? ""
                appState.onboarding.markPassed(.practice)
            }
            if readiness.canPractise { fieldFocused = true }
        }
        .onDisappear { appState.practiceDelivery?.practiceField = nil }
        // Practice opens by itself as soon as the model is ready.
        .onChange(of: readiness.canPractise) { _, canPractise in if canPractise { fieldFocused = true } }
    }

    private var shortcutCard: some View {
        OnboardingCard {
            HStack(spacing: 14) {
                FlowKeycap(title: appState.settings.hotkeyDisplayName, compact: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your shortcut").font(FlowStyle.callout.weight(.medium))
                    Text(appState.settings.recordingMode == .holdToTalk
                         ? "Hold it to talk, then let go to paste. It works in every app."
                         : "Press it to start, then press again to paste. It works in every app.")
                        .font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Change shortcut…") { openSettings() }
                    .accessibilityHint("Opens Settings, where you can choose another key.")
            }
            .accessibilityElement(children: .contain)
            if appState.settings.hotkey == .fn && appState.hasGlobeKeyConflict {
                OnboardingNotice(tone: .warning, text: "Your 🌐 key also does something of its own. In Keyboard settings, set “Press 🌐 key to” to Do Nothing, or change the shortcut.")
                Button("Open Keyboard Settings") { SystemSettingsLink.open(SystemSettingsLink.keyboard) }
            }
        }
    }

    private func modelCard(_ readiness: OnboardingPracticeReadiness) -> some View {
        OnboardingCard {
            if let headline = readiness.headline {
                Text(headline).font(FlowStyle.callout.weight(.medium))
                    .foregroundStyle(readiness.offersRetry ? FlowStyle.danger : FlowStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if readiness.showsProgress {
                if let fraction = readiness.progressFraction {
                    ProgressView(value: fraction) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(FlowStyle.caption.monospacedDigit()).foregroundStyle(FlowStyle.muted)
                    }
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Speech model download")
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel("Speech model")
                }
            }
            if let detail = readiness.detail {
                Text(detail).font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if readiness.offersRetry {
                Button("Retry") { model.start(.retry, appState: appState) }
            }
        }
    }

    private func placeholder(_ readiness: OnboardingPracticeReadiness) -> String {
        if !readiness.canPractise { return "Ready when the speech model is." }
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
            OnboardingNotice(tone: .success, text: "That’s it. What you said, typed for you.")
        case .corrected:
            OnboardingNotice(tone: .success, text: "WhiskerFlow kept only what you meant: “\(transcript)”")
        case .notCorrected:
            OnboardingNotice(tone: .warning, text: "The correction stayed in. To have WhiskerFlow tidy these up, turn on “Recognize clear spoken corrections” in Assistant.")
        case .different:
            OnboardingNotice(tone: .info, text: "That’s what WhiskerFlow heard. Try the sentence again if you like.")
        }
    }
}

// MARK: - 4. Done

struct OnboardingDoneStep: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let presentation = DictationPresentation(appState: appState)
        VStack(spacing: 12) {
            OnboardingHeading(symbol: "checkmark.seal", title: "You’re all set.",
                              detail: "Click where you’d type in any app and \(presentation.gesture.lowercased()) \(appState.settings.hotkeySpokenName).")
            OnboardingCard {
                shortcutRow(keys: appState.settings.hotkeyDisplayName, action: "Dictate", detail: presentation.gesture == "Hold" ? "Hold, speak, let go" : "Press to start, press to stop")
                shortcutRow(keys: "⎋ Esc", action: "Discard the dictation", detail: "Press while dictating")
                Divider()
                shortcutRow(keys: "⌥⇧⌘E", action: "Voice edit a selection", detail: "Hold and say how to change it")
                shortcutRow(keys: "⌥⇧⌘N", action: "Quick voice capture", detail: "Hold to save a note")
                shortcutRow(keys: "⌥⇧⌘R", action: "Start or stop meeting recording", detail: "Press in any app")
                shortcutRow(keys: "⌥⇧⌘B", action: "Bookmark the meeting", detail: "Press while recording")
                Divider()
                shortcutRow(keys: FlowDestination.shortcutRangeLabel, action: "Switch screens", detail: "In the WhiskerFlow window")
            }
            OnboardingCard {
                Text("When you want them").font(FlowStyle.callout.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                extraRow(symbol: "person.2.wave.2", title: "Meeting recording",
                         detail: "Record meetings to Atlas. Set it up in Settings → Meetings.",
                         action: "Open Settings")
                extraRow(symbol: "building.2", title: "Client vocabulary",
                         detail: "Choose the client you’re working for in Assistant, so their names come out right.",
                         action: nil)
                extraRow(symbol: "keyboard", title: "Shortcut and language",
                         detail: "Change them in Settings → Dictation.",
                         action: "Open Settings")
            }
            Text("You can run setup again from Help → Run Setup Again, the menu bar or Settings → App.")
                .font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
    }

    private func shortcutRow(keys: String, action: String, detail: String) -> some View {
        HStack(spacing: 14) {
            FlowKeycap(title: keys, compact: true).frame(minWidth: 96, alignment: .leading)
            Text(action).font(FlowStyle.callout)
            Spacer()
            Text(detail).font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func extraRow(symbol: String, title: String, detail: String, action: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(FlowStyle.accent).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FlowStyle.callout)
                Text(detail).font(FlowStyle.caption).foregroundStyle(FlowStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let action {
                Button(action) { openSettings() }
                    .accessibilityLabel("\(action.replacingOccurrences(of: "…", with: "")) for \(title.lowercased())")
            }
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
        guard UIPreview.mode == "onboarding-practice", UIPreview.onboardingModelPhase == nil else { return nil }
        return (.selfCorrection, [
            .sample: "WhiskerFlow turns what I say into text, right where my cursor is.",
            .selfCorrection: "Let’s meet at 3."
        ])
    }
}
