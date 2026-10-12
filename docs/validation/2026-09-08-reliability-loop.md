# WhiskerFlow reliability loop — 8 September 2026

Work only in `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant`, branch `codex/whiskerflow-2-assistant`. Preserve unrelated edits and the main checkout. User authorises relevant local fixes, trusted diagnostic tools, testing, signing and reopening the app. No public release or merge is authorised.

## Each review

Run `python3 script/review_diagnostics.py --hours 2` and `python3 script/review_stability.py`. Compare `.codex/diagnostic-review-state.json` to avoid repeating notifications. Inspect content-free diagnostics in `~/Library/Logs/WhiskerFlow/diagnostics*.jsonl` and sanitised `stacks/stall-*.json`; never inspect transcript/history contents merely for monitoring.

Correlate launch, PID, build, session and capture IDs. Main-thread stalls trigger a one-second native sample, at most once per five minutes. Only main-thread symbol frames persist in three rotating files; raw paths, addresses and other threads are discarded. Resource snapshots provide context, not proof of causation.

Investigate fresh faults, reproduce a relevant failing check, apply a focused correction and run appropriate tests plus diff inspection. If evidence is insufficient, improve diagnostics or reproduce the suspect path; avoid speculative changes solely to claim activity. Build/sign a candidate before stopping anything. Confirm no active recording, meeting, transcription or pending save immediately before switching. Keep one app instance. If busy, defer the switch. Verify the new process/build and Ready state; record separately whether an actual microphone-to-paste journey was exercised.

## Accepted stability gate

Jacob accepted at least 50 successful dictations across three active days, with no hangs, failed deliveries or unusually slow completions. `script/review_stability.py` persists evidence across log rotation and restarts. After a relevant behaviour fix, run `python3 script/review_stability.py --reset '<build and reason>'`; retain prior-window summaries.

The provisional machine thresholds are normal recordings of at most 60 seconds with finish p95 at most 2 seconds, and no finish exceeding the greater of 5 seconds or 10 percent of recording duration. Inspect the ledger for missing lifecycle events and user-reported failures too. Unverified or clipboard-only receipts do not prove successful insertion: the automated gate is necessary evidence, not sufficient release approval. Require a fresh actual microphone-to-paste check and existing release checks before cleanup is declared successful.

## Cleanup after stability

Preserve a recoverable evidence snapshot. Remove temporary LocalDiagnosticLog, MainThreadHealthMonitor, ResourceDiagnosticSampler and StallStackCapture instrumentation, temporary stage/lifecycle logging, diagnostic launch flags and diagnostic-only helpers/tests as appropriate. Keep functional lifecycle/paste fixes and established error/crash reporting. Build and verify a clean signed app, reopen only when idle, and verify a real dictation journey. Repair any cleanup regression and resume observation. Pause the automation only after a verified clean candidate; report remaining release blockers without publishing.

## Current evidence and validation

The 08:57–08:59 incidents included main-thread stalls up to 39.71 seconds and text-processing stages of 23.84 and 27.39 seconds. CPU and thermal snapshots did not establish their cause. Expanded stack capture is intended to identify the blocked call on recurrence; it is not a fix for an established root cause.

The Reliability candidate passed 11 targeted tests covering stack sampling/parsing, diagnostic privacy, resource sampling, bounded paste verification and delivery lifecycle. Native sampling succeeded in tests. The signed bundle passed codesign verification. No deliberate stall was introduced into the user app. Live stability remains to be demonstrated.

The Reliability app was reopened through a normal AppKit quit request after the old app showed Ready. Its replacement UI showed Dictate Ready. New app_started diagnostics confirmed the new signed build. No fresh microphone-to-paste test was performed in this change; user use will provide live evidence. Clipboard-only results are excluded from the successful-dictation count and block the gate.

User-requested copy change: normal verified/unverified paste receipts now display only “Pasted”. Receipt states and diagnostic outcomes remain intact; actual failures and clipboard-only instructions remain actionable. The signed Simple Paste candidate builds successfully. This wording-only change does not reset the stability window. Current Run action targets `.build/WhiskerFlow 2 Simple Paste.app`.

## 11:30 BST review

Five stalls on the Simple Paste build since gate inception; 50 dictations at review, one active day, p95 4.95 seconds, maximum finish 7.30 seconds. Two idle stalls overlapped 90–100 percent system CPU and heavy swap traffic. This is correlation only. One sanitised capture showed SwiftUI graph work; another was captured after recovery and showed an idle runloop. Both recognition/text-processing capture attempts failed after about two seconds, with no prior categorical reason retained.

Added bounded categorical capture failure reasons and elapsed time, without raw errors/reports. Regression test failed before the allowlist change, then all seven local-log and native sampler tests passed. Independently inspected the changed sampler/allowlist and ran diff whitespace checks. Signed Capture Diagnostics candidate built and passed codesign. Waited for dictation to finish, checked Ready and no active meeting capture, quit normally and reopened the new candidate. New app_started build/PID and Ready UI verified. No fresh microphone-to-paste journey or forced app stall was performed; real-use acceptance remains outstanding. This diagnostic-only change does not reset prior faults or claim to repair the underlying stall. Current Run action targets `.build/WhiskerFlow 2 Capture Diagnostics.app`.

## 13:30 BST review

Capture Diagnostics remains running as PID 71506. It recorded 28 completed dictations, maximum finish 3.413 seconds, no delivery failure, and two stalls outside logged dictation stages. Both native captures succeeded. Sanitised frames contain SwiftUI/layout work; one capture completed after recovery, so it cannot by itself identify the blocked operation. Completion time includes symbolication, not just sampling. One stall coincided with nearly 100% system CPU; this is not proof of causation.

Enhanced the content-free review helper with capture start/completion/recovery correlation keyed by launch/PID/build/capture ID, categorical failures, and finish latency by build (previously only paste latency was summarised). Fixture checks covered ordering, cross-launch isolation, missing starts and finish durations; live report and diff whitespace checks passed. App source unchanged, so no rebuild/restart or stability reset. Gate remains unmet: 80 completions on one day, nine cumulative fault events. Continue observation; do not infer that the intermittent dictation stall is fixed or remove diagnostics.

## 15:30 BST review

Reviewed fresh lifecycle evidence and both requested reports. No new stalls or stack captures in the two-hour window. 28 finish returns (maximum 2.279 seconds); 26 paste returns (maximum 0.971 seconds), no failed delivery. Two failure states occurred after extremely short captures: 4,797 samples (about 0.30 seconds) with recognition failure and zero samples respectively. Finish returned in 141ms and 21ms, so these were not stuck transcriptions. Code confirms zero-sample handling can represent no audio or conversion failure; current telemetry cannot distinguish those, and the exact recognition error is unavailable. Do not label them successful or assume accidental hotkey presses. Both remain in the cumulative fault ledger.

Current PID71506 remains running. No new evidence supports an app behaviour change or restart; continued real-use observation is the useful next step. Gate remains unmet at 106 delivered dictations over one day, 11 fault events and prior slow finishes. No cleanup/reset. Quiet review: no user action needed.

## 17:30 BST review

18 further dictations completed with paired finish lifecycles and 18 paste returns; maximum finish 1.812 seconds and maximum paste 0.974 seconds. No new stalls, failures, capture files or unfinished sessions. Fresh telemetry and PID71506 confirm the known candidate is still running. No application changes or restart warranted. Preserve observations: cumulative gate has 124 completions on one active day and 11 prior fault events, so it remains unmet. Quiet review; continued observation is the next useful validation step.

## 19:30 BST review

20 finish returns, 18 paste returns and two zero-sample captures. Those failures returned in 169–173ms before recognition; they do not demonstrate a hang or establish why no samples arrived. No new observed stalls or stack captures. Maximum finish 1.909s; maximum paste 1.235s. Coverage contains gaps (largest about 942s), so this is observed-event evidence only, not continuous health proof. Wall/uptime gap comparisons are retained in review state. Fresh telemetry and PID71506 confirm the app remains running. No restart or speculative behaviour change. Gate retained at 142 delivered dictations, one active day, 13 fault events; no diagnostic cleanup. Quiet review of recurring brief empty captures; no new user action.

## 10 September 08:56 BST catch-up

Last saved review was 8 September 19:31 BST. Ran recent and catch-up summaries rather than assuming continuous review coverage. Since then, three recovered stalls: 3.16 seconds around a recognition retry, then 9.07 and 6.64 seconds at a new launch (PID1255, same signed build). System-load readings overlapped stalls but do not establish cause. Capture failures now distinguish no_frames and terminated. The latter completed after11.8s; the eight-second termination timer is best-effort under system scheduling pressure, not a hard wall-clock guarantee.

Ran the built-in native sample against the current PID as a bounded, read-only diagnostic experiment. It exited successfully with a recognised main-thread header and a report below the1MB retention cap. Raw report stayed in subprocess memory and was not saved. This does not reproduce the fault-time failure and does not justify assuming permanent permissions or parser failure. Existing sanitised capture files predate these events. No speculative app edit or restart. Current app has fresh telemetry; recent eight paste deliveries completed, nine finishes max1.702s, one zero-sample capture returned18ms. Repeated background recognition failures in the catch-up data require care: state_changed can retain an earlier recording session, so they are not proof that all failures share that recording. Gate remains unmet at168 completions over two active days with29 cumulative fault events. Keep diagnostics and continue observation.

## 10 September 09:30 BST review

New recognition stall and 5.636s completion; system CPU about15 percent, memory-pressure warning. Recurrent no_frames means prior classification is insufficient. Added four numeric report-shape counters on failed capture: retained UTF-8 bytes, thread headers, main-thread headers and symbol lines. Counts permit distinguishing missing sections, unsymbolicated output and possible retention cap without retaining raw report text. Review helper exposes these counters. No recognition/paste behaviour changed.

Eight targeted native sampler/parser/privacy tests passed, including missing-header versus missing-symbol fixtures. Diff checked and code independently inspected for content-free numeric output. Signed Capture Shape candidate built and passed codesign. Old app was Ready, with automatic meeting recording off and prior meeting saved locally; normal quit completed. Opened new candidate, verified Ready and fresh app_started. No new microphone-to-paste or forced-stall acceptance yet; instrumentation-only change leaves stability window and faults intact. Run action now targets `.build/WhiskerFlow 2 Capture Shape.app`.

## 10 September 11:30 BST review

13 completed dictations on Capture Shape; no new failure states, main-thread stalls or stack captures. Slowest finish4.998s for398,397 samples (24.9s): recognition3.810s, paste0.994s, text processing5.5ms, history1ms. This observation localises delay before paste; it does not establish engine root cause or reproduce the original stuck delivery. No new report-shape failure evidence, and no justified app edit or restart. PID45358 is running with fresh telemetry. Gate remains unmet at193 completed deliveries over two active days,32 prior fault events and three earlier slow completions. Preserve diagnostics. Quiet review; no new user action.

## 10 September 13:30 BST review

Four recovered stalls,24 completed dictations, two no_frames capture failures. New report counters establish that failed reports contain symbolised threads but lack the optional com.apple.main-thread queue label (one report244,470 bytes,29 thread headers,zero labelled main headers). Parser previously depended on that label. Reproduced loss with a fixture and failing test, then added exact numeric thread-ID matching. ID is captured during main-thread initialisation via pthread_threadid_np; existing label matching remains a fallback. No raw reports or user data persisted. Native self-sample with queue label removed verifies the ID matches sample output; fixture also excludes partial ID matches and other threads.

Ten targeted tests passed after fixing a Swift stored-property initialiser compile error; signed bundle and whitespace checks passed. Independently inspected thread identity initialisation and exact-match boundaries. Reopened idle Thread Capture app, verified Ready and app_started build/PID. No new real dictation or live stall acceptance yet. This repairs diagnostic capture only, not the intermittent dictation delay; keep existing stability faults/window. Run action points to `.build/WhiskerFlow 2 Thread Capture.app`.

## 10 September 15:30 BST review

Thread-ID capture worked on a real stall. Capture07A8FA94-6EE6-4995-B7B1-257BAD32DCDD contains RenderBox surface allocation and QuartzCore waitForCommitId/CA::Context::synchronize on the main thread. One7.019s dictation completion overlapped text_processing. CPU16 percent and normal memory pressure do not establish resource cause; capture completion after recovery also limits exact interval inference. This is evidence of rendering waits, not proof of slow string processing or a specific offending view.

Separated detached text-processing work duration from completion-to-main-actor-resume delay using monotonic timestamps. Only worker_elapsed_ms/resume_delay_ms numeric metadata are added to the existing event; review helper exposes them for slow stages. Six privacy/lifecycle tests passed, code diff inspected, signed build validated. Reopened idle Resume Timing app via normal quit; Ready and new build/PID verified. No new microphone-to-paste or timing event on the new build observed yet. Diagnostic-only change; no stability reset or underlying-fix claim. Run action now points to `.build/WhiskerFlow 2 Resume Timing.app`.

## 10 September 17:30 BST review

Ten real-use dictations on Resume Timing completed within1.697s; all ten pasted, no new hangs or failures. Verified worker_elapsed_ms and resume_delay_ms are present in all ten real processing events. Maxima (ms): {"worker_elapsed_ms": 3.60625000030268, "resume_delay_ms": 3.649166665127268}. No new stack captures or slow processing to attribute. Current PID66196 remains running with fresh telemetry. No app change/restart warranted. Keep diagnostics and failed cumulative gate (241 completions,two active days,39 prior fault events). Quiet review; no user action.

## 11 September 09:30 BST catch-up

Last saved review10 September17:31 BST. Catch-up finds38 completed deliveries with no new faults or stalls. Latest two hours26 deliveries, maximum finish3.797s and p952.358s. Live timing maxima (ms): {"worker_elapsed_ms": 5.151124998519663, "resume_delay_ms": 872.8575000059209}. No new stack files. PID66196 remains running with fresh telemetry. Three active days reached, but cumulative gate remains failed at279 deliveries,39 historical fault events,seven slow completions and p953.584s. Do not treat the day/count thresholds alone as passing or clear prior failures. No justified application edit/restart; continue existing observation. Quiet review.

## 11 September 11:30 BST review

Three further dictations completed within1.506s with paste max975ms. Paired finish events, no new stalls/failures or stack files. PID66196 remains running with fresh diagnostics. No code change or restart justified. Gate remains unmet:282 delivered dictations,three active days,39 historical fault events and seven slow completions. Existing instrumentation remains ready for recurrence. Quiet review.

## 11 September 13:30 BST review

14 finish returns,13 paste receipts,no new main-thread stalls or stack captures. One512,000-sample recording failed during recognition and returned in974ms. Another recognition attempt nine seconds later also failed; its stage ID differs while state_changed retains the previous recording session. Inspected catch/retry code; do not assume these are necessarily the same recording. Exact typed error is unavailable in content-free diagnostics. No justified speculative engine fix or restart. Next instrumentation should add allowlisted failure category with explicit attempt/record identity, without raw error strings. Current PID66196 remains running. Gate remains failed at295 completions,41 fault events. New substantive recording failure notified; no hang-fix claim.

## 11 September 15:30 BST review and saved-recording repair

Completed the interrupted user-requested repair. Original 14:30 recording reproducibly failed with the independent 30-second file decoder, while whole-sample decoding recovered 1,224 characters. Replaced app-side independent windows with FluidAudio transcribeDiskBacked, retaining library chunk context and bounded disk-backed memory. Opt-in local regression uses the saved recording without checking in audio or printing transcript text; it failed before the fix and passes afterwards with at least 90 percent of reference text length. Five recovery/preparation/lifecycle tests passed. Signed Decode Recovery candidate and diff checks passed.

Old candidate was Ready before normal quit. Verified it exited, opened Decode Recovery, verified single PID85547, build3c91b3d28f68-20260911T133454Z and Ready UI. Original recording retried successfully through app History and persisted as transcribed (226 words / 1,224 characters). Manual History retry has no external destination; destination-unavailable is expected and is not a live paste acceptance. A separate14:53 recording still returns emptyTranscript on this build; retain as unresolved, do not claim all recording failures fixed.

Two-hour pre-switch review:56 finish returns,52 paste receipts,18 failure-state events, no main-thread stalls or new stack capture events; max finish4.174s,p953.124s. Prior cumulative window preserved at347 completions,three days,59faults. Start a new observation window after this relevant decoder fix and manual recovery checks. Run action now points to Decode Recovery. Continue investigation of remaining empty recording and original intermittent rendering-related hangs. Fresh real microphone-to-paste acceptance on this candidate remains pending; no release-readiness claim.

## 11 September 17:30 BST review

Decode Recovery PID85547 remains running with fresh telemetry. One post-reset real dictation completed in1.447s, including983ms unverified paste; no new failure states, stalls or stack captures. Old retained stack files unchanged. Two-hour report includes pre-reset manual recovery failure; do not count it as a new post-reset fault. Gate1 completion/1day,zero faults; not passing, insertion accuracy not verified.

Replayed remaining14:53 saved clip through opt-in FailedRecordingRecoveryTests: emptyTranscript reproduced in0.795s. Inspected WAV signal locally without retaining audio/text as telemetry:3.8s,mono16kHzPCM16,peak30/32768,RMS1.096/32768 (approximately-89.5dBFS RMS). This extremely low signal distinguishes it from the recovered92.5s decoder failure; it does not establish whether intended speech was absent or lost during capture. No decoder change justified from this evidence and no need to restart working candidate. If this pattern recurs, add bounded per-record input-level/route evidence; preserve current diagnostics and original hang investigation.

## 11 September 19:30 BST review

One further real dictation completed in1.359s with932ms unverified paste. No new faults, main-thread stalls or stack captures; retained stack files unchanged. Decode Recovery PID85547 running with fresh telemetry. Post-fix gate2 completions/1day,zero faults,normal p951.447s; insufficient use to qualify, actual insertion remains unverified. No justified edit/restart or repeat replay of the already-characterised faint recording. Preserve diagnostics and pending investigations. Quiet review.

## 11 September 21:30 BST review

Four further real dictations completed, maximum finish2.031s and paste981ms. No new faults, stalls or stack captures; existing stack files unchanged. Decode Recovery PID85547 running with fresh telemetry. Post-fix gate6 completions/1day,zero faults,normal-dictation p951.833s; all six paste receipts unverified. Insufficient volume/days for qualification; keep diagnostics and pending investigations. No justified edit/restart. Quiet review.

## 12 September 07:30 BST review — background recovery fix awaiting unlock

Last2h idle with fresh telemetry. Overnight catch-up adds5 successful completions <=1.536s plus2 recovered main-thread stalls at23:35 UTC, no active dictation stage. System CPU90–97percent,memory warning correlated but do not alone establish cause. CaptureF7FD22DA-22B4-4174-9B36-CF51E36E54EB on Decode Recovery PID85547 identifies MeetingCaptureCoordinator.scheduleUploadRetry -> EncryptedMeetingChunkStore.recoverSessions -> checksum/file reads on main thread. Capture finished after recovery; exact sampled interval uncertain. Gate11 completions/1day,2faults,not passing.

Added real coordinator/store regression with FileManager assertion against main-thread directory scan. Red before worker change, green afterwards. Routed all3 coordinator recovery scans through utility Task.detached with cancellation checks and handler; recheck active capture/delivery after suspension before starting retry batch, preserve deferred retry if capture starts during initial recovery.39 coordinator/capture/responsiveness tests pass; diff checked and inspected. Cancellation cannot interrupt an already-running synchronous store scan but discards its result. Other synchronous store consumers could still contend on its lock; no blanket hang-resolution claim.

Built signed `.build/WhiskerFlow 2 Background Recovery.app`. Build-time verification passed; sandboxed follow-up misleadingly reported invalid signature, full-access deep/strict verification passed including nested Sparkle. Dictation UI Ready observed on old app, but Mac locked before meeting-state check. Do not terminate, switch or reset gate while safe state is unverified. Old Decode Recovery stays running; Run action unchanged. Pending candidate and deployment steps in review state. Need unlock, safe app switch, fresh process/build/Ready and actual relevant journey, then post-fix stability reset.

## 12 September 09:30 BST review — background recovery deployed

No new dictations/faults/stalls/captures during2h review. Existing retained stacks unchanged, fresh telemetry; previous window11completions/2faults. Mac accessible: verified Dictate Ready, Meetings shows Record meeting, Automatic recording off, previous meeting saved locally. Normal quit completed; verified no remaining process, signature verified, opened Background Recovery. Single PID52813/build3c91b3d28f68-20260912T063306Z and fresh app_started/Ready confirmed. Run action updated. Prior39tests pass; fresh microphone-to-paste and recovery-under-load acceptance still pending. Start post-fix observation window preserving prior failure evidence. No release-readiness claim.

## 12 September 11:30 BST review

Background Recovery PID52813 running with fresh telemetry. No post-deployment dictations, faults, stalls or new stack captures; retained stacks unchanged. Gate0 completions, no active usage days. Idle runtime does not qualify microphone-to-paste or retry-under-load acceptance. No justified edit/restart; preserve diagnostics and pending real-use checks. Quiet review.

## 12 September 13:30 BST review

One failed capture at12:07 BST:1600samples/100ms, finish269.9ms,no paste. Saved error metadata reports minimum300ms16kHz requirement; verified FluidAudio ASRConstants.minimumAudioDurationSeconds=0.3. Capture state lasted~377ms after readiness; no evidence establishes whether user intended longer speech. This is a short-input rejection, not observed main-thread stall or long-file decoder regression. No new stacks/stalls; Background Recovery PID52813 running with fresh telemetry. Gate0completions/1fault preserved. Inspected live fallback path; it passes short audio into decoder. Do not pad or discard audio merely to turn gate green; potential next UX improvement is explicit too-short feedback. No speculative decoder edit/restart.

## 12 September 15:30 BST review

No new dictations, faults, main-thread stalls or stack captures during2h window. Background Recovery PID52813 running with fresh telemetry; stack files unchanged. Gate remains0completions/1prior short-input fault. No new evidence justifies decoder edits or restart; preserve existing diagnostics, failure and pending real-use acceptance. Quiet review.

## 12 September 17:30 BST review — deep stack candidate pending idle

11 finish returns/10 paste receipts,max finish2.518s;16 recovered main-thread stalls,2 terminated sampler attempts,3successful captures. New stacks EE3A974A,83EDCC87,163D2B59 show SwiftUI AppGraph/scenesDidChange/main-menu update work; no active transcription stages during stalls in report. Memory pressure warning/system load correlate, not proven cause. Two retained traces hit64frame prefix cap.

Reproduced deep-call loss with100frame fixture (red). Parser now retains first16 and last48 for long traces, same64frame/3file/privacy limits; new frame_retention_policy marks noncontiguous excerpts.20sampler/privacy/log tests passed, signed Deep Stack built and strict verification passed, diff inspected. This improves diagnostics only, not proven UI fix. Dictation Ready seen, but user interaction twice invalidated UI before meeting-idle check; do not interrupt. Candidate `.build/WhiskerFlow 2 Deep Stack.app` pending safe switch. Running Background Recovery PID52813 and Run action unchanged. Keep gate10completions/19faults and prior evidence; no reset for diagnostic-only change.

## 12 September 19:30 BST review — Deep Stack deployed

Nine further dictations completed <=1.589s,no new faults/stalls/captures, retained stacks unchanged. Gate19completions/1day,19faults,p952.518s. Verified Dictate Ready and no meeting capture; meeting saved locally, automatic recording off. Auto-review initially rejected quit for pending retry; inspected AppDelegate/AppState save-drain and coordinator cancellation path, then normal quit approved and process exit verified. Opened signed Deep Stack; singlePID65649/build3c91b3d28f68-20260912T163306Z/app_started/Ready verified. Run action updated. No stability reset for diagnostics-only change. New real capture/microphone-to-paste validation pending; retain unresolved SwiftUI stalls and existing evidence.

## 12 September 21:30 BST review — sampler completion budget

Deep Stack window17finish returns/14paste receipts,13 additional successful deliveries,max finish4.779s. Three recovered stalls,2sampler processes terminated after13.237/16.077s wall time despite8s utility-queue cutoff; no new retained stack. Memory warning/critical and high load observed but not root-cause proof. Two failures1597sample captures below300ms minimum; one empty capture; one failed paste sessionC1DCD4E1-B97C-4735-ADAC-3699C2B69A49 after931197samples. Saved short-capture error metadata checked without retaining content. Exact paste failure category unavailable.

Increase bounded report completion cutoff8to20s to allow observed slow completion; actual sampling remains1s at10ms,1MB in-memory cap,3files,5min cooldown unchanged. Native sampler/privacy20tests passed; signed Stack Budget validated. This is an evidence-collection adjustment, no claim that symbolication specifically caused delay or that under-load success is proven. Dictation Ready/no meeting capture/meeting saved confirmed, normal quit and process exit verified, opened Stack Budget. SinglePID20412/build3c91b3d28f68-20260912T203338Z/Ready/app_started verified. Run action updated. Keep gate32completions/1day,29faults,p952.518s; diagnostic-only, no reset. New microphone-to-paste and live stall capture acceptance pending.

## 13 September 07:30 BST review — asynchronous sound cues

Auto-review first misread06:30UTC as London time; verified IANA Europe/London07:30BST, retry approved. Overnight7deliveries,max finish5.562s (long recording allowed proportional threshold),one recovered stall. New capture1CA412A3 on Stack Budget PID20412 succeeded2.600s,first16/last48policy present. Main-thread excerpt includes SoundService.play -> NSSound/AVAudioPlayer startup -> audio-device mutex wait/file reads; later paste LaunchServices work also present. Sample completed after recovery and spans changing work, so it does not assign entire stall to sound. Prior gate39completions/1day,30faults,p952.518s.

Focused real SoundService seam test reproduced main-thread playback before fix. All sound lookup/play now confined to one serial utility queue; caller returns immediately, queued cues older1s skipped, autoreleasepool per playback. Four sound/delivery/recovery tests passed, signed Async Sounds candidate and diff verified. Consulted Apple NSSound documentation and Cocoa threading summary; keep sound objects on serialized playback path. No sound content or transcript telemetry. completion_sound timing now measures enqueue, not physical playback.

Dictation Ready, meeting saved locally/no active capture, automatic recording off verified. Normal quit/exit verified, opened Async Sounds; singlePID36324/build3c91b3d28f68-20260913T063404Z/app_started/Ready confirmed. Run action updated; new stability window for relevant behavior fix, retain prior evidence. New actual sound playback/microphone-to-paste acceptance pending. Other SwiftUI stalls/paste failure unresolved; no release-ready claim.

## 13 September 09:30 BST review

Ten real dictations completed on Async Sounds,maximum finish1.429s,paste985ms. No new faults,main-thread stalls or stack captures; retained stack files unchanged. PID36324 running with fresh telemetry. Gate10completions/1active day,zero faults; does not yet pass accepted volume/day requirements. All10paste receipts unverified, so actual destination insertion and hardware sound playback remain unconfirmed. No justified edit/restart; continue observation. Quiet review.

## 13 September 11:30 BST review (delivered11:43)

No new dictations/faults/stalls/captures. Same Async Sounds PID36324 running; latest telemetry3s old, but only3heartbeats/10resource snapshots during2h window. Sparse interval is unavailable evidence, not continuous healthy-runtime proof; no inference of sleep cause. Retained stack files unchanged. Gate10completions/1day/0faults remains unmet. No justified edit/restart; continue real-use observation. Quiet review.

## 13 September delayed daytime review — 18:08 BST

No new dictations/faults/stalls/captures in2h window or3.4h catch-up from saved review timestamp. Only2heartbeats/9resource snapshots in2h, latest4s; Async Sounds PID36324 remains running. Sparse intervals are unavailable evidence, not health proof. Retained stack files unchanged. Gate10completions/1day/0faults; no qualification, no justified edit/restart. Keep diagnostics and pending real-use checks. Quiet review.

## 13 September review — 19:00 BST

No new dictations/faults/stalls/captures. Only3heartbeats/11resource snapshots in2h; latest1s and Async Sounds PID36324 running. Sparse intervals remain unavailable evidence; retained stacks unchanged. Gate10completions/1day/zero faults,not passing. No justified edit/restart. Preserve diagnostics and pending real-use acceptance. Quiet review.

## 13 September review — 20:59 BST

No new dictations/faults/stalls/captures. Initial2h snapshot only1heartbeat/8resource events and736s stale; follow-up verified fresh heartbeat/resource events9s old, same Async Sounds PID36324 running. Missing intervals remain unavailable evidence; no inference of stall or sleep solely from gaps. Retained stacks unchanged. Gate10completions/1day/0faults,not passing. No justified edit/restart. Quiet review.

## 13 September final review — 21:32 BST

One zero-sample capture session7E545EEF: recording state to finish34ms,finish5.36ms; failure reports transcribing=false. Inspected zero-input guard: exits before recognition/persistence, so no saved failed transcript or paste; numeric conversionFailures not retained in local event, cannot distinguish no buffers from all conversion failures. No new stalls/stacks. Async Sounds PID36324 running, latest6s; coverage35heartbeats/146resource snapshots remains incomplete. Gate10completions/1day/1fault retained. No evidence justifies decoder fix or restart; possible next bounded probe is conversion-failure count on decode_returned if recurrent.

## 14 September 07:30 BST review

Overnight9.97h catch-up has no new dictations/faults/stalls/captures,214heartbeats/863resource snapshots. Latest2h sparse3heartbeats/10resource samples,latest10s. Async Sounds PID36324 remains running; missing intervals unavailable evidence, retained stacks unchanged. Gate10completions/1active day/1priorfault; idle calendar time does not add active days. No justified edit/restart. Keep diagnostics and pending real-use acceptance. Quiet review.

## 14 September 09:30 BST review

43dictations completed with43paste receipts,max2.443s,window p951.813s. One recovered main-thread stall outside active recognition stages; capture451C7C68 completed5.229s after recovery and contains SwiftUI ForEach/view-list/AttributeGraph/MainMenuItemHost work. Memory warning/38percent CPU correlate, not cause proof. Async Sounds PID36324 remains running. Gate53completions/2active days/2faults,normal p951.748s; count threshold met but faults/day threshold prevent passing.

Used SwiftUI performance-audit skill for code-first scene/menu dependency review. WhiskerFlowApp scene reads meetingStatus and isRecording for MenuBarExtra icon; meeting-status transitions can rebuild scene while visible icon unchanged. ContentView supplies focused copy closure and TranscriptCommands observes it. These are candidate invalidation sources only; no expensive synchronous body work or unstable data identity established in inspected command code. Next useful discriminator is scene/menu update-count profiling or deterministic repeated status-transition repro; do not claim root cause or make speculative UI refactor. Preserve diagnostics; no restart warranted.

## 14 September 11:30 BST review — scoped menu observation

20finish returns/19paste receipts,one failure,five recovered UI stalls,two new captures.09BFACD8 shows DynamicBody/update and WhiskerFlowApp copies;2A50F950 shows command accumulator/main-menu construction. Prior gate72completions/2days/8faults,p951.748s,not passing.

Constructed actual MenuBarExtra scene under withObservationTracking. Harness initially needed Bindable extraction and missing import fixes; once compiled, recording mutation reproduced scene invalidation (red). Extracted menu scene and moved state-dependent icon into separate label View; same test green and verifies label still invalidates. Four scene/delivery/sound tests pass, diff reviewed, signed Scoped Menu strict verification passed. This proves reduced scene dependency, not full reproduction/removal of intermittent stall. Existing settings binding and icon branches preserved.

Dictate Ready,meeting saved locally/no active capture,automatic recording off verified. Normal quit and process exit verified,opened Scoped Menu; singlePID82277/build3c91b3d28f68-20260914T103431Z/app_started/Ready confirmed. Run action updated; new observation window for relevant UI behavior fix preserves prior failure window. Actual icon/menu/settings/microphone-to-paste acceptance still pending; no release-readiness claim.

## 14 September 13:30 BST review

First post-scoping window16real dictations completed <=1.727s,16paste receipts all unverified. No new failure states,main-thread stalls or stack captures; retained stacks unchanged. Scoped Menu PID82277 running with fresh telemetry. Gate16completions/1active day/0faults,insufficient volume/days. Real lifecycle completes, but actual icon/menu/settings behavior and insertion remain unverified. No justified edit/restart; continue observation and preserve diagnostics. Quiet review.

## 14 September 17:30 BST review

Fresh telemetry (6s age),120heartbeats/487resource samples,no dictation attempts or new recorded faults in the two-hour window. Scoped Menu PID82277 still running; all three sanitized stack files unchanged from prior build (latest09:24 UTC). Cumulative gate24completions/1active day/0recorded faults,p951.726s,23unverified deliveries; insufficient volume/days and insertion acceptance remains outstanding. User report at15:33 remains unmatched: latest logged dictation14:25,last logged failure10:02/4800samples; clarification already requested. Do not infer the reported failure is resolved from clean telemetry. No justified behavior edit or restart; preserve diagnostics and pending acceptance. Quiet review.

## 14 September 19:30 BST review

120heartbeats/489resource samples,latest event2s old; no dictation attempts,new faults or captures in two hours. Scoped Menu PID82277 running. All retained captures correlate to previous build/PID36324 and unchanged IDs/timestamps. Gate remains24completions/1active day/0recorded faults,p951.726s,23unverified receipts. User-reported failure remains unmatched and acceptance pending; no release claim. No justified edit or restart; diagnostics retained without resetting window. Quiet review.

## 14 September 21:30 BST review

95heartbeats/389resource samples in two hours,latest event8s old. No observed dictations,new faults or captures; missing telemetry intervals are unavailable evidence,not proof of continuous health or sleep. Scoped Menu PID82277 running. Retained captures unchanged and all from prior build/PID36324. Gate24completions/1active day/0recorded faults,p951.726s,23unverified receipts; not passing. Unmatched user report and real insertion/feature acceptance remain pending. No justified change or restart; preserve diagnostics and window. Quiet review.

## 15 September 07:30 BST review

115heartbeats/464resource samples,latest event9s old; no observed dictations,new faults or captures in two hours. Missing intervals remain unavailable evidence. Scoped Menu PID82277 running; retained captures unchanged from prior build/PID36324. Cumulative gate24completions/1active day/0recorded faults,p951.726s,23unverified receipts. A new calendar day without dictations does not count as an active day. User report remains unmatched and actual insertion/feature acceptance outstanding. No justified edit or restart; preserve diagnostics and window. Quiet review.

## 15 September 09:30 BST review — schedule cache deduplication

39dictations/39receipts,max2.093s,p951.863s. Two recovered idle UI stalls4.478s/3.398s on Scoped Menu PID82277. Capture5B42F530-E684-4BF0-BAE5-DD1F03703068/current build shows MeetingCaptureCoordinator.pollSchedule -> AppSettings.cacheMeetingSchedule -> UserDefaults/KVO/preferences encoding. Captured samples include work after recovery; not attribution of the full stall. Memory warning/swap occupancy are context only. Gate63completions/2active days/2faults,p951.821s,not passing.

Actual cache method rewrote identical schedules. Added MeetingScheduleCacheTests with counting UserDefaults: red2writes instead of1 on repeated poll; fixed by comparing decoded bounded50-entry cache before encoding/writing. Changed/empty schedules still persist. Four cache/recovery/delivery tests green. Diff checked; signed Schedule Cache bundle built and validated. Logs /tmp/whiskerflow-schedule-{red,green,build}.log. This prevents redundant preferences work,not proof all stalls are removed; changed-cache writes remain synchronous and actual schedule/offline acceptance pending.

Switch deferred: first UI check Listening0:44,then Ready/Pasted at09:34,but next refreshed check Listening0:09. Did not quit or interrupt. Candidate .build/WhiskerFlow 2 Schedule Cache.app queued in review state; current Run action and stability window unchanged. Next review should switch when idle,verify new PID/build/Ready and relevant journey,then reset window.
