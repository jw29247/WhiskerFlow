import AppKit
import SwiftUI
import WhiskerFlowAppSupport

/// First-run setup: one screen per step. Step order, "is this satisfied" and
/// resume live in `OnboardingFlow`; this view renders them and runs the checks.
struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var model = OnboardingModelWatch()
    private var onboarding: OnboardingController { appState.onboarding }

    var body: some View {
        let conditions = appState.onboardingConditions
        let step = onboarding.current
        VStack(spacing: 0) {
            header(step: step, conditions: conditions)
            // Scrolls rather than clips when the window is made shorter.
            ScrollView {
                switch step {
                case .permissions: OnboardingPermissionsStep(appState: appState)
                case .microphone: OnboardingMicrophoneStep(appState: appState)
                case .practice: OnboardingPracticeStep(appState: appState, model: model)
                case .done: OnboardingDoneStep(appState: appState)
                }
            }
            .id(step)
            .contentMargins(.horizontal, 44, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer(step: step, conditions: conditions)
        }
        // Wider would only add empty space; taller or shorter is the user's call.
        .frame(width: 660)
        .frame(minHeight: 460, idealHeight: 640, maxHeight: .infinity)
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
            // The download starts at launch, so it is usually ready by the
            // practice screen. Start it only if it never started or failed.
            model.network.start()
            model.start(.setupOpened, appState: appState)
        }
        .onDisappear { model.network.stop() }
        .onChange(of: model.network.isOnline) { _, online in
            if online { model.start(.cameOnline, appState: appState) }
        }
        .onChange(of: appState.hasGlobeKeyConflict, initial: true) { _, _ in applyDefaultShortcut() }
    }

    /// Setup no longer asks for a shortcut: fn unless macOS won't let
    /// WhiskerFlow have it (`OnboardingDefaults.shortcut`).
    private func applyDefaultShortcut() {
        guard !UIPreview.isEnabled,
              let shortcut = OnboardingDefaults.shortcut(current: appState.settings.hotkey,
                                                         personChoseShortcut: appState.settings.hotkeyWasChosen,
                                                         fnReservedForDictation: !appState.hasGlobeKeyConflict) else { return }
        appState.settings.hotkey = shortcut
        appState.reloadHotkey()
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
        let satisfied = item != .done && onboarding.flow.isSatisfied(item, conditions)
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
            if step != .permissions && step != .done {
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
        case .permissions: return "Continue"
        case .practice where !satisfied: return "Skip practice"
        case .done: return "Start using WhiskerFlow"
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
            modelReady: modelState == .ready
        )
    }
}

/// The speech model as setup sees it, and the one place setup starts it.
@MainActor
@Observable
final class OnboardingModelWatch {
    let network = NetworkReachability()

    func phase(of appState: AppState) -> OnboardingModelPhase {
        #if DEBUG
        if let preview = UIPreview.onboardingModelPhase { return preview }
        #endif
        switch appState.modelState {
        case .unloaded: return .notStarted
        case .ready: return .ready
        case .preparing:
            let download = appState.modelDownload
            guard appState.settings.engine == .parakeetTDTv3 else { return .loading }
            if download.isCompiling { return .optimising }
            return download.needsDownload ? .downloading(fraction: download.fraction) : .loading
        case .failed:
            // Read only after a failure, never on the dictation path.
            return .failed(OnboardingModelFailure.classify(
                neededDownload: appState.modelDownload.needsDownload,
                isOnline: network.isOnline,
                availableBytes: Self.availableBytes(),
                downloadBytes: StagedDownloadProgress.parakeetDownloadBytes
            ))
        }
    }

    /// Starts the preparation unless one is running or done, so setup never
    /// begins a second download.
    func start(_ trigger: OnboardingModelTrigger, appState: AppState) {
        guard OnboardingModelPolicy.shouldStart(phase(of: appState), trigger: trigger) else { return }
        appState.warmUpEngine()
    }

    private static func availableBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
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
                    .accessibilityHidden(true)
            }
            Text(title).font(FlowStyle.title).tracking(-0.6)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(FlowStyle.body).foregroundStyle(FlowStyle.muted)
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
        case .success: return FlowStyle.success
        case .warning: return FlowStyle.warning
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
            .foregroundStyle(granted ? FlowStyle.success : FlowStyle.muted)
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
