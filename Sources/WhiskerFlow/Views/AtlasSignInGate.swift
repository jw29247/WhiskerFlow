import AppKit
import SwiftUI

/// WhiskerFlow needs an Atlas account: it is how the company leaderboard
/// knows who you are, and what meetings, the Assistant and client vocabulary
/// connect to. Until you sign in, this replaces the main window and the
/// dictation key opens it instead of recording.
struct AtlasSignInGate: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(FlowStyle.accent)
            Text("Sign in with Atlas to use WhiskerFlow")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("WhiskerFlow now uses your Atlas account for the team leaderboard, meeting recordings, the Assistant and each client's vocabulary. Dictation starts working as soon as you're signed in.")
                .font(.callout)
                .foregroundStyle(FlowStyle.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                appState.signInToAtlas()
            } label: {
                Text(appState.isSigningInToAtlas ? "Waiting for Atlas…" : "Sign in with Atlas")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(appState.isSigningInToAtlas)
            if let error = appState.atlasSignInError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Label("The leaderboard shows your name and daily counts (words, time saved, streak, meetings) to colleagues. Never any text.",
                  systemImage: "trophy")
                .font(.system(size: 11))
                .foregroundStyle(FlowStyle.muted)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowStyle.canvas)
    }
}

/// Opens the main window when a dictation press needs sign-in first,
/// whichever scene is alive to do it.
struct AtlasSignInPresenter: ViewModifier {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: appState.atlasSignInRequests) { _, _ in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
    }
}
