# Native visual Meet speaker fallback — 16 September 2026

## Problem and implementation

The live Meet PWA exposes participant label bounds, but not the expected `NAME is speaking` label or video-tile bounds. The old reader therefore produced no named evidence. Native IPC occasionally returned cannotComplete for role/position requests and invalidated the entire snapshot.

The reader now scans windows (excluding menu trees), uses nonempty title/value fallback for name labels, treats missing optional bounds as an unavailable candidate rather than discarding the call, and permits50ms per request within a500ms scan budget. Required read failures remain unavailable.

When explicit activity is absent, the app transiently captures only the matching Meet window using ScreenCaptureKit. Pixel analysis runs on a utility worker. It finds a connected blue tile outline, requires opposing edges plus the same tile's blue activity badge and dark waveform, and matches exactly one bottom-left AX name inside that outline. Roster order and microphone state never assign identities. Duplicate names, overlapping candidates, changed tab/window/labels, incomplete reads and ambiguous intervals remain unnamed. A second native snapshot verifies the window and labels after capture. Consecutive agreeing observations use the existing encrypted speaker timeline and conservative transcript matcher.

Frames stay in memory, are capped at2048pixels on their longest side, and are never written or uploaded by this feature. Each ScreenCaptureKit callback has a350ms deadline; late callbacks cannot resume twice. The existing local transcription and authorised Atlas sync remain unchanged. Product permission wording now discloses local image analysis. Telemetry contains only counts and bounded outcomes. The DEBUG-only `--probe-native-meet` entrypoint starts no audio, AppState, meeting upload or evidence writer.

## Evidence

- Original native live probes returned unavailable on AX role/position IPC errors, or a snapshot with zero candidate tiles. A diagnostic helper initially aborted while constructing SCContentFilter without an NSApplication/window-server connection; the helper now initializes NSApplication with prohibited activation. The real recording process never stopped.
- Real tool-observed frames at11:20 and11:32 exercise different highlighted participants. Both detected correctly; inactive tiles and border-only/badge-only fixtures reject.
- Final signed probe:10/10valid snapshots,6active detections,3consecutive timeline intervals,461–639ms per complete read. No names or images in probe logs. This is native reader/timeline proof, not proof of complete meeting transcript attribution.
- Focused tests:17executed,1explicit caption probe skipped,0failures (both image fixtures enabled); encrypted-store/local-processor and competing-speaker matching covered.
- Signed candidate `.build/WhiskerFlow 2 Visual Speakers.app`; build `3c91b3d28f68-20260916T103420Z`. Signature verification and diff whitespace checks pass.

## Deployment and limits

Candidate is not yet the recording app. Meeting Retry remains running to preserve the active ad hoc continuation. Switch only after recording and pending save are idle; verify a fresh recording and encrypted visual evidence in the installed app. Do not reset the stability window before actually installing.

Validated against the current four-tile Meet PWA layout and two participants' visible indicators. Background/minimized, PiP, presentation layouts, themes, browser zoom changes and every participant's final attribution remain unverified. Unsupported indicators remain generic; this is not release acceptance. Existing first-part upload/finalization failure, calendar cutoff and approx15second recording gap are separate unresolved issues.

Recall lists Meet PWA unsupported: https://docs.recall.ai/docs/meeting-platforms (checked16September). No Recall code or dependency is used. Native screenshot API: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager .


## 13:33 BST activation
Normal quit after Dictate Ready and all retained nonempty meeting manifests failed (no active capture/save); old PID992 exited. Codesign strict verification passed. Visual Speakers build3c91b3d28f68-20260916T103420Z launched asPID92075; app_started and Ready verified. Meetings recovery resumed automatically. Run action updated and stability window reset, preserving prior18completions/2days/1fault. No fresh microphone-to-paste or installed native meeting attribution acceptance yet. First part C807 has audio receipt but decoder-empty mixed windows190–200s,300–310s,600–610s prevented transcription; sources retained. Continuation removed by application; independent Atlas outcome pending.

## 17 September 07:34 BST calendar-boundary guard
Overnight telemetry contained heartbeats and resource samples only: no new dictation, stall or failure events. Added `MeetingCaptureStopPolicy` and routed scheduled-stop expiry through a bounded Meet presence check. A calendar end now stops a scheduled recording only for explicit `.noMeeting` or `.notJoined`; `.available`, `.multipleMeetings` and `.unavailable` keep the recording alive and retry the check after the five-minute grace. This prevents an ongoing call being cut off by its calendar end while failing open when Accessibility is ambiguous or unavailable. Focused accessibility/coordinator tests passed (37 tests, zero failures); `git diff --check` passed; the signed bundle passed strict codesign verification. Old PID92075 was idle (Dictate Ready, no active capture/save), so it was quit normally. New bundle `WhiskerFlow 2 Visual Speakers Calendar Safe.app`, build `3c91b3d28f68-20260917T063338Z`, launched as PID46246; Dictate Ready and Meetings recovery UI verified. Recovery is processing a retained recording; no further restart until idle. The stability window was reset for this behavior fix. Real overrun acceptance still requires a future scheduled Meet that runs beyond its calendar end.
## 17 September 09:32 BST resource-pressure review
The Calendar Safe build recorded six completed dictations (finish p95 1,532ms, no dictation failure) but also four recovered main-thread stall events. The stalls occurred at 08:15, 08:18, 08:25 and 08:27 BST while system CPU was 57–83%, load was 17–37, swap was approximately 19–21GB and memory pressure was warning/critical; WhiskerFlow itself was using roughly 1–4% CPU. Two bounded captures retained only AppKit run-loop and low-level Swift concurrency frames, with no blocking WhiskerFlow call. This is correlation with system resource pressure, not proof of causation. No code change or restart is justified by this evidence; keep the diagnostic window and wait for a recurrence with a more specific application frame. The app remains running as PID46246; no active recording or pending user save was interrupted.

## 17 September 13:40 BST recognition-render stall and finished-call review

The 12:25 BST dictation on Calendar Safe had a 22.8-second main-thread stall during recognition. The sanitized stack was in SwiftUI `DisplayList.ViewUpdater`, QuartzCore transaction commits and RenderBox/Metal work; memory pressure was normal and the post-stall text processing, history save and paste each completed within milliseconds. The transcribing HUD's indefinite SF Symbol animation was the only continuous animation on that state, so it was removed. The focused HUD test passed, strict codesign passed, and Render Safe build `3c91b3d28f68-20260917T123842Z` launched as PID83479 after the old process was idle and terminated. Its UI is Dictate Ready; this new stability window has no post-launch dictation yet.

The user's finished Meet call produced no new capture session: Meetings showed `Record meeting`, automatic recording was off, and the only retained local retry was an older failed recording with no speaker-evidence files. Speaker recognition for this call is therefore unverified and no participant names can be claimed. Keep the native AX plus in-memory visual fallback for a future scheduled call, with no captions, extension or cloud audio dependency.

After relaunch, Render Safe completed one fresh dictation at 13:41 BST in 1.70 seconds. The UI returned to Dictate Ready with a Pasted receipt and no new fault or stall. This is an initial post-fix observation, not stability-gate completion.

## 17 September 15:42 BST short-capture failure guard

The review window found the latest retry-queue failure was an invalid 100 ms capture, below Parakeet's 300 ms input minimum. A second failed record was an 800 ms complete capture with only background-level signal and no audible activity. Added `CapturedAudioValidation` before the file transcription path: empty captures, audible captures below 300 ms, and complete silent captures are discarded locally before a retry record is created; long recordings with only a resident tail remain recoverable. The WAV is removed only for those non-dictation captures, and the lifecycle log records a bounded reason and sample count without audio or transcript content.

The focused validation tests and full suite pass (396 tests, 8 expected skips). Render Safe build `3c91b3d28f68-20260917T144129Z` is signed and running as PID63173. The fresh UI is Dictate Ready; the two historical retry records remain visible for review, but no new post-fix dictation has been used to advance the accepted 50-dictation/three-day stability gate.

## 17 September 18:46 BST completed-call review and retry fix

The completed `WAR ROOM` session `C80739A1-BB1E-40E0-BC27-508A54025B52` is retained locally and has an uploaded receipt for all 513 chunks (28m20.5s across microphone, mixed and system tracks, with no source gap). Local post-call processing still failed on an audible mixed window at 100–110 seconds after a transient empty model result. A bounded replay through 210 seconds processed 51 turns and identified seven anonymous diarized speakers, but the session contained no encrypted speaker-evidence files or named Meet activity, so participant names remain unverified.

Meeting processing now retries an audible single-chunk empty decode three times before marking the session failed. The native Meet reader also accepts Chromium's static-text `NAME is speaking` announcement while excluding caption regions. Focused speaker and retry regressions passed; the full suite reached 402 tests with eight expected skips, with only the pre-existing macOS temporary-directory permission failure in `CorrectionStoreTests`. Signed Render Safe build `3c91b3d28f68-20260917T174554Z` is running as PID1578. The stability window was reset for this build; no post-fix dictation has been recorded yet.

At 19:20 BST the final instrumented Render Safe build `3c91b3d28f68-20260917T182011Z` relaunched as PID2187. Recovery had returned the C807 manifest to `awaitingTranscription` and was actively retrying it, so the app was left running and no further build switch was attempted while that worker was busy. The next review must verify whether the retry reaches an Atlas completion receipt before treating the meeting as recovered.

The 19:26 retry reached the same 600–610 second window and failed after the full-chunk retries. A real local replay of 580–620 seconds completed in 49.2 seconds with 22 turns, including speech through the previously failing region. Added a second bounded fallback that decodes each persistent audible 10-second failure as two 5-second slices, preserves absolute timestamps and still fails closed when every slice is empty. The fallback regression and existing audible-empty guard both pass. Render Safe build `3c91b3d28f68-20260917T183728Z` is signed and running as PID3670; the stability window was reset for this build.
