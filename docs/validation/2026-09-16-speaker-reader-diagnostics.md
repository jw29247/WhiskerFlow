# Native Meet speaker check — 16 September 2026

Live WAR ROOM recording began at 10:36 BST. At 10:43, all four participants were visible and CC was off. A participant tile visibly showed the blue active-speaker outline and activity icon while the native accessibility snapshot reported no corresponding activity label. The production reader reported unavailable, not its separate waiting-for-activity state. There may therefore be two problems: snapshot rejection and unsupported activity grammar. Roster names do not establish speaking intervals.

Source diagnostics now distinguish missing, multiple and prejoin Meet areas; incomplete, timeout and oversized reads; and calendar-call mismatch. Fixed strings only, with no additional names, transcript contents, URLs, screenshots or audio stored in telemetry. Existing 200ms/700-node/32-depth limits, encryption and strict speaker grammar remain unchanged. This is diagnostic clarification, not a speaker-recognition fix.

Validation: `swift test -j 2 --filter MeetingAccessibilityEvidenceTests` compiled the app and passed seven tests. The new test distinguishes absent/multiple/prejoin/wrong-origin trees from a valid joined call with no speaking evidence. Existing activity, caption exclusion and timeline tests pass. `git diff --check` passed.

Not bundled or installed during the active call. Preserve the current recording and pending save. Build/sign and switch only when idle. Use the resulting reason to target the next probe. The in-call visual observation does not justify silently adding screenshot capture or guessing speaker names.
