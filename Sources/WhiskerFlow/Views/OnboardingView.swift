import AppKit
import SwiftUI
import WhiskerFlowAppSupport

/// First-run setup: one screen per step. Step order, "is this satisfied" and
/// resume live in `OnboardingFlow`; this view renders them and runs the checks.
struct OnboardingView: View {
    @Bindable var appState: AppState
    private var onboarding: OnboardingController { appState.onboarding }

    var body: some View {
        let conditions = appState.onboardingConditions
        let step = onboarding.current
        VStack(spacing: 0) {
            header(step: step, conditions: conditions)
            Group {
                switch step {
                case .welcome: OnboardingWelcomeStep(appState: appState)
                case .permissions: OnboardingPermissionsStep(appState: appState)
                case .microphone: OnboardingMicrophoneStep(appState: appState)
                case .shortcut: OnboardingShortcutStep(appState: appState)
                case .language: OnboardingLanguageStep(appState: appState)
                case .model: OnboardingModelStep(appState: appState)
                case .practice: OnboardingPracticeStep(appState: appState)
                case .extras: OnboardingExtrasStep(appState: appState)
                case .done: OnboardingDoneStep(appState: appState)
                }
            }
            .id(step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            footer(step: step, conditions: conditions)
        }
        .frame(width: 660, height: 640)
        .background(FlowStyle.canvas).foregroundStyle(FlowStyle.ink).tint(FlowStyle.accent)
        .onDisappear {
            // Closing the window is "Set up later"; finishing clears the flag first.
            if onboarding.isPresented { onboarding.dismiss() }
        }
        .task {
            // Permissions change in System Settings, outside the app: poll while
            // setup is on screen. Both checks are local and cheap.
            guard !UIPreview.isEnabled else { return }
            while !Task.isCancelled {
                appState.refreshMicrophonePermission()
                appState.refreshAccessibilityPermission()
                appState.refreshScreenRecordingPermission()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            // The download starts at launch; make sure a failed or never-started
            // preparation is running again from the first screen on.
            if appState.modelState == .unloaded || appState.modelState.isFailure { appState.warmUpEngine() }
        }
    }

    private func header(step: OnboardingStep, conditions: OnboardingConditions) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    progressDot(item, current: step, conditions: conditions)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup step \(step.index + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            if step != .done {
                Button("Set up later") { onboarding.dismiss() }
                    .buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
            }
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
    }

    private func progressDot(_ item: OnboardingStep, current: OnboardingStep, conditions: OnboardingConditions) -> some View {
        let satisfied = item != .done && item != .welcome && onboarding.flow.isSatisfied(item, conditions)
        let isCurrent = item == current
        let reachable = onboarding.flow.canJump(to: item)
        return Button { onboarding.jump(to: item) } label: {
            ZStack {
                Capsule()
                    .fill(isCurrent ? FlowStyle.accent : (item < current || satisfied ? FlowStyle.accent.opacity(0.35) : FlowStyle.line))
                    .frame(width: isCurrent ? 30 : 18, height: satisfied && !isCurrent ? 14 : 5)
                if satisfied && !isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(FlowStyle.accent)
                }
            }
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!reachable)
        .help(item.title + (satisfied ? " · done" : ""))
        .accessibilityLabel("\(item.title)\(satisfied ? ", done" : "")\(isCurrent ? ", current" : "")")
    }

    private func footer(step: OnboardingStep, conditions: OnboardingConditions) -> some View {
        let satisfied = onboarding.flow.isSatisfied(step, conditions)
        return HStack {
            if step != .welcome && step != .done {
                Button("Back") { onboarding.back() }.buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
            }
            Spacer()
            if step == .permissions && !conditions.permissionsReady {
                Text("Allow both to continue").font(.caption).foregroundStyle(FlowStyle.muted)
            }
            Button(primaryTitle(step: step, satisfied: satisfied)) { onboarding.advance(appState.onboardingConditions) }
                .buttonStyle(FlowPrimaryButtonStyle())
                .keyboardShortcut(step == .practice ? nil : .defaultAction)
                .disabled(!onboarding.flow.canContinue(conditions))
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }

    private func primaryTitle(step: OnboardingStep, satisfied: Bool) -> String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Start using WhiskerFlow"
        case .model where !satisfied: return "Continue while it downloads"
        case .extras where !satisfied: return "Skip for now"
        case .permissions: return "Continue"
        default: return satisfied ? "Continue" : "Skip this step"
        }
    }
}

extension AppState {
    /// What setup reads from the system on every render.
    var onboardingConditions: OnboardingConditions {
        OnboardingConditions(
            microphoneGranted: hasMicrophonePermission,
            accessibilityGranted: hasAccessibilityPermission,
            modelReady: modelState == .ready,
            atlasConnected: isAtlasPaired,
            meetingRecordingReady: settings.meetingModeEnabled && hasScreenRecordingPermission
        )
    }
}

extension ModelState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Shared pieces for the setup screens.
struct OnboardingHeading: View {
    let symbol: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(FlowStyle.accent)
            }
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.6)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 14)).foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
        }
        .padding(.top, 18).padding(.bottom, 22)
    }
}

struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(FlowStyle.line, lineWidth: 1))
    }
}

struct OnboardingNotice: View {
    enum Tone { case success, warning, info }
    let tone: Tone
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private var symbol: String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .success: return .green
        case .warning: return .orange
        case .info: return FlowStyle.accent
        }
    }
}

struct OnboardingStatusBadge: View {
    let granted: Bool
    var grantedText = "Allowed"
    var pendingText = "Not allowed yet"

    var body: some View {
        Label(granted ? grantedText : pendingText, systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium))
            .foregroundStyle(granted ? Color.green : FlowStyle.muted)
    }
}

/// "Run setup again" for the Help menu, the menu bar and Settings: restarts
/// setup from the welcome screen in its own window.
struct RunSetupAgainButton: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Run Setup Again…") {
            appState.onboarding.restart()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: OnboardingWindow.id)
        }
    }
}

/// Keeps the setup window in step with `OnboardingController.isPresented`,
/// whichever scene (main window or menu bar) is alive to do it.
enum OnboardingWindow {
    static let id = "onboarding"

    struct Presenter: ViewModifier {
        let onboarding: OnboardingController
        @Environment(\.openWindow) private var openWindow
        @Environment(\.dismissWindow) private var dismissWindow

        func body(content: Content) -> some View {
            content
                .onAppear { if onboarding.isPresented { open() } }
                .onChange(of: onboarding.isPresented) { _, presented in
                    if presented { open() } else { dismissWindow(id: OnboardingWindow.id) }
                }
        }

        private func open() {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: OnboardingWindow.id)
        }
    }
}
