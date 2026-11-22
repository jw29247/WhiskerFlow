import SwiftUI

/// The one confirmation before signing out of Atlas, shown in place in the
/// Atlas section. While a meeting records or waits to be sent it explains
/// why sign-out has to wait instead.
struct AtlasSignOutConfirmation: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let blocker = appState.atlasSignOutBlocker {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You can’t sign out yet").font(.headline)
                        Text(blocker).font(.callout).foregroundStyle(FlowStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(FlowStyle.recording)
                }
                HStack {
                    Spacer()
                    Button("OK") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
            } else {
                Text("Sign out of Atlas?").font(.headline)
                Text(appState.atlasSignOutConfirmation).font(.callout).foregroundStyle(FlowStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = appState.atlasSignOutError {
                    Text(error).font(.caption).foregroundStyle(FlowStyle.recording)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Sign out", role: .destructive) {
                        if appState.signOutOfAtlas() { isPresented = false }
                    }
                    .buttonStyle(.borderedProminent).tint(FlowStyle.recording)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
