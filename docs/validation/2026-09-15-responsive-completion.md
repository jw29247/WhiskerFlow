# Dictation completion responsiveness

Running signed build: 3c91b3d28f68-20260915T113943Z, `.build/WhiskerFlow 2 Responsive Completion.app`.

User reported completion remains stuck until the main window opens. Numeric logs on previous build show an 81,152 ms finish and a 3.658 ms text worker with 7,318 ms main-actor resumption delay. Sanitized stall capture FE4F0E13-F386-4C00-A26B-1148A7CD435E includes synchronous CacheDelete/free-space XPC and Keychain reads under MeetingCaptureCoordinator on the main thread. Another capture contains RenderBox/QuartzCore commit waits; that separate path remains unresolved.

Regression command: `swift test --filter MeetingCoordinatorTests.testMeetingSystemProbesNeverBlockDictationMainActor`. Before executor fix: 2 assertion failures (disk, credential probes on main). After moving both into detached utility work and rechecking status ownership after awaits: 30 focused coordinator, recovery responsiveness and delivery lifecycle tests pass. This tests a confirmed main-thread blocker, not full reproduction of the window-activation symptom.

Signing verified strict. Normal quit occurred only after Ready and saved/attention meeting status, old process exit confirmed. New Ready UI verified; main window then closed. Need real hidden-window microphone-to-paste acceptance, latency and no-stall evidence before calling the complete regression resolved. The existing saved meeting still needed retry; names/transcripts/notes remain unverified.
