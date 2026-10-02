# Meeting retry backoff

Review found94 identical mixed20,000–30,000ms empty-window events for retained session F1262067-54E6-4D9D-A0E9-660E555C777C. The retry scheduler retried all retained recordings every60seconds. Two-hour diagnostics contained25 main-thread stalls and a40.09second dictation finish. This overlap is not proof that retries caused every stall; rendered SwiftUI samples remain inconclusive.

Added per-session bounded retry delays60,300,900,3600seconds, using monotonic uptime. Further failures stay at3600seconds. The queue skips cooled-down sessions, leaving new sessions eligible. Success clears that session, explicit Retry clears cooldowns, cancellation does not count as failure. Restart permits a fresh recovery attempt; cooldown is in-memory. Source recordings remain encrypted and retained.

Policy test failed4assertions against existing60second behavior, then passed;39 focused tests passed including recovery ownership, joined-call gating and dictation delivery. Reviewed integration in all failure paths and retry selection, diff whitespace passed.

Signed `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant/.build/WhiskerFlow 2 Meeting Retry.app`, build3c91b3d28f68-20260915T143349Z, normal-launched after current app showed saved/attention and no active recording/upload. Old process exit and new Ready verified. Includes previously pending joined-call guard; automatic recording remains off until live acceptance. No fresh microphone journey or long-enough live backoff interval yet verified. No claim to fix the decoder or window-opening stall.


16 September09:30 review: live retry spacing64.7,315.3,936.8,3661.8seconds confirms intended1/5/15/60minute backoff including processing/scheduling overhead. Subsequent intervals remain approximately hourly; sleep extends elapsed wall-clock spacing. Current process992/build unchanged. No new dictations or stalls in last2h; stability window has2completed dictations on1day,p951934.6ms,0faults—not sufficient for release. F12620–30s still fails ASR. Bounded audio-only test passed decryption and160000samples pertrack, RMS mic0.002824/system0.012515/mixed0.006744. This proves nonzero stored audio, not speech content or decoder cause. No replay ASR or remote transmission performed. Keep retained sources and10:30live validation.
