import AppKit
import Foundation
import Logging
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// One dictation from key press to delivered text: begin, finish, transcribe
/// and deliver. `AppState` owns it and forwards to it.
///
/// Everything here runs on the main actor and is called synchronously, as it
/// was inside `AppState`. State a view reads stays on `AppState` (which is
/// `@Observable`) and is reached through the forwarding properties below, so
/// every SwiftUI read still registers; state only the lifecycle reads lives
/// here.
@MainActor
final class DictationLifecycle {
    /// `AppState` owns this object and lives for the whole process.
    unowned let app: AppState

    init(app: AppState) {
        self.app = app
    }
}
