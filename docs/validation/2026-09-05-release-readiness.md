# Release readiness work in progress

The user requested continued repair and end-to-end verification on 5 September. WhiskerFlow must remain unmerged. The active goal finishes only when the candidate is release-ready; this document is an evidence ledger, not a passing release certificate.

## Deployment baseline

Atlas PR #3543 merged as `8b325312c861f68b75aa2c365771ed0b8d7f6e95` at 08:20:12 UTC. Six review findings were addressed. The final focused repository gate passed 6,259 tests. Production workflow `33954980671` succeeded, and the Convex application revision and web health matched that SHA.

WhiskerFlow PR #13 remains open at baseline `b39188c7437e6a7efdc53881923daf740006cbee`, with auto-merge disabled. Subsequent readiness repairs are not yet accepted.

## Fresh native UI acceptance

| Journey | Observed result | Remaining proof |
| --- | --- | --- |
| Local note to Atlas | Passed: local save followed by private Atlas acknowledgement | Recheck final candidate and all three kinds |
| Selection capture | Failed against selected text in AppKit fixture; diagnostic probe pending | Live rewrite, fidelity, stale refusal, exactly-once replacement and Undo |
| Offline preparation | Passed: goal/agenda preserved in local plan, cloud disabled | Recheck final candidate |
| Live Atlas preparation | Failed with generic terminal-job message | Resolve backend failure and assess real provider output |
| Meeting capture | Passed: a fresh synthetic audio recording captured mic and Mac audio | Recheck final memory repair |
| Live coaching | Passed: observed activity, uncertainty label, and actual prompt; pause/resume/hide/show worked | Check cooldown/dismissal and final candidate |
| Bookmarks | Passed: button at 00:13 and shortcut at 00:29; both visible locally | Atlas acknowledgement and restart durability |
| Stop and recap | Passed: stopped at 124,760 ms; local recap shown | Final transcript, Atlas notes and private post-review |
| Meeting delivery | Fresh session `94389D82-177B-4D0C-97B4-DC0413971D02` obtained an Atlas meeting reference but was still awaiting transcription | Complete actual processing; an older recovery status incorrectly replaced current status |
| Voice drafts and spoken corrections | Pending | Actual audio through shortcut and final text |
| Learned corrections | Pending | Edit a real pasted result, observe saved issue, exercise correction |
| App profiles and client vocabulary | Prior fixture checks only | Fresh live client refresh, isolation and dictation |
| Paste recovery | Prior synthetic preview only | Actual delivery, uncertainty/failure path and Undo |

The synthetic meeting contained a £150 budget (not £500), Alex/Friday, and an explicitly unapproved release. No real meeting participant was recruited for the test. One clearly labelled private synthetic note remains in Atlas as acceptance evidence.

## Resource failure and repair requirements

The user reported repeated 17 GB app memory use. The preview exited before a physical-footprint sample could be collected; the user report is not mislabeled as a measured process sample. The machine had about 8 GB of swap used after exit. Earlier crashes include a Core ML prediction-buffer assertion and a separate Core ML AOT-serialization assertion; neither crash alone identifies a model or proves memory as its cause.

Source inspection found whole-file decoding of a pending three-hour recording, WhisperKit's default 16 concurrent workers on macOS, and model-reference replacement after an abandoning timeout while underlying work could still be running. Candidate repairs must bound audio windows and concurrency and retain exclusivity until actual work settles, including cancellation. They require regression and live-load proof.

Reinstallable old Swift build/dependency directories and inactive application caches were removed. Source, signed preview, validation evidence, settings, transcripts, encrypted recordings and keys were preserved. Free space rose from critically low levels to about 10 GB after the app exited. Disk figures vary with swap and recompilation.

The user explicitly accepted resource measurements on this M5/16 GB machine to estimate M1/8 GB suitability. The final report must separate that estimate from actual M1 measurements. Capture CPU, RSS, physical footprint and peak, memory pressure, swap and disk using `script/monitor_resources.py`, including idle, dictation, capture, final processing and repeated cycles.

Temporary test preferences: the original shortcut was fn/Globe with Hold to talk; testing switched it to F5 with Tap to start/stop. Restore the original after acceptance. Do not run the installed app and candidate together.

## 09:56 UTC resource and live acceptance update

The bounded GPU candidate crashed after about 46 seconds with captured MPSGraph assertion `shape.count = 0 != strides.count = 4`; its sampled footprint reached 3.0G. Changing only meeting encoder/decoder compute units to CPU/Neural Engine produced a signed differential candidate (PID 63040). It remained running for approximately 29 minutes, completed the older three-hour recovery queue, and completed a fresh recording upload. Sampled app RSS peaked at 874,971,136 bytes and separate ANECompilerService RSS at 2,424,979,456 bytes. Later app physical footprint was 244.0M, peak 437.4M; compiler returned to about 103MB RSS. Logs: `/tmp/whiskerflow-ane-resource-samples.jsonl` and `/tmp/whiskerflow-ane-system-services.jsonl`. The controlled benchmark interval ends at 09:56 UTC before compiler tests resume; later samples are not uncontaminated system-load evidence.

The initial synthetic meeting is verified in authenticated Atlas UI with complete notes/transcript, Alex/Friday, £150 not £500, and unapproved release preserved. Both bookmarks displayed In Atlas in native UI. The new ANE recording (local session 6F8DDEC8-6701-4F57-AAF9-D3D5639A9608, listed 5 September 10:51) has only ten segments through 0:56 and omits expected speech after 60 seconds. Its final phrase also substitutes registered for ready. This is a failed transcription-fidelity acceptance, under investigation, despite bounded memory and successful delivery.

Normal three-second selection capture passed once the external fixture actually became foreground using its normal Window menu. The earlier failure was not reproduced with correct foreground activation. Temporary DEBUG selection probe removed from source. Live cloud rewrite/replacement remains pending.

Atlas diagnostics PR #3546 merged as 7d627033a518c8a299d2da0995241d0c310727fd; deployment still pending. Full native suite remains failed on protected correction-file reopen; no protection weakening or test skip applied.

## 10:29 UTC acceptance update

Scoped native commits 4fc83e1 (coach panel/reminders/chronology, 16 tests) and eba0f762 (30-second ASR windows/audible-empty retention,25 tests) each received independent scoped PASS. Signed Validation.app PID70600 contains these plus the experimental CPU/ANE backend and parent safe-error presentation. Fresh actual session D7D681BC-2A50-44B0-B18C-CF9F210E061B, duration105440ms, reached Atlas meeting vh8ew8rv6sey1bzs4wvvrs4ren8dtayh with14segments. Authenticated UI verified the entire synthetic final sentence after1:00, £150 not£500, Alex beforeFriday, and no release approval. This resolves the previous whole-tail omission in this repeated real journey; general ASR perfection is not claimed. Sampled physical peak476.0M and later footprint~243M; no crash observed.

Live private coach preparation passed. Post-meeting review first returned assistant_invalid_output safely, then explicit retry succeeded with exact transcript excerpts/timestamps at0:16,0:19,0:23,0:29,0:46,0:54,1:00. Review stays in native private coach; no team communication. All three draft kinds (note/task/client update) have explicit local-save then Atlas acknowledgements; test client update attached to authorized Manukora and clearly labelled synthetic/private.

Playback failed: browser audio disabled. Deployed HTTP policy confirmed media-src none; storage HEAD200 audio/wav. Bounded CSP fix allows only configured Convex storage origin, currently in Atlas follow-up packet under review alongside deadline fidelity. Actual professional rewrite changed beforeFriday to byFriday; explicit synthetic replacement worked and app reported verifiedpaste, but semantic fidelity failed. Fixture Undo menu selector was incorrect (undo instead of undo:); fixture corrected/rebuilt, fresh Undo acceptance pending.

Client refresh and explicit selection passed. Local Manukora term Glimmer Dock -> GlimmerDock-QA disappears for Daisy London and returns on switching back. Polished profile saved specifically for Acceptance Editor. Actual vocabulary/profile application remains pending. Restore original No client and Standard fixture profile after testing; remove synthetic client term.

Speaker mute explained missing microphone activity in system-audio-only tests. Temporarily set moderate volume for spoken test, then restored exact81.25% and Mute on. Targeted CUA key events sent to external editor do not reach WhiskerFlow global NSEvent monitor; sending F5 directly to WhiskerFlow triggers its normal local handler. Dictation captured spoken audio and saved history, but displayed Transcribing afterward and did not reach editor (self-target rejected). Safe lifecycle probe pending to classify stale status. Spoken multi-sentence repair also remained unchanged despite optionenabled; sentence-level conservative repair under test.

## 21:45 UTC acceptance update

Native HEAD 7871d0d removes the second (blue) recording level meter, retaining the red waveform, and raises the private coach panel to the recording HUD's status-bar level. The signed Feedback.app was tested with the main window closed: the separate Private meeting coach panel remained available; Pause changed to Resume and displayed that recording continues, Resume restored estimates, and Bookmark confirmed 04:10. The capture was explicitly stopped via File > Toggle Meeting Capture; reopening Meetings showed Record meeting, three saved bookmarks, and the recording saved in Atlas. All 16 MeetingAssistantTests passed in `/tmp/whiskerflow-feedback-coach-tests.log`. The screen capture of the private panel is blank; this does not prove visibility during every third-party screen-sharing implementation or every fullscreen app.

The earlier quick-voice test was interrupted by an approximately eleven-hour task pause and is not passing evidence. Its app was no longer running when work resumed; a failed recording remains recoverable. Do not automatically retry that potentially long recording. The prior resource sampler covered only one hour (peak physical footprint 530.5M), not the entire elapsed period.

CorrectionStoreTests reran and still fail on protected-file reopen with NSCocoaErrorDomain 257 / EPERM. Log: `/tmp/whiskerflow-correction-store-evening.log`. No test skip or protection change was made. The native full suite remains unproven.

Atlas repair HEAD 695dbad30ed6f1cf6bd2beb57c9606f2c0d67411 received independent exact-head PASS after repairing the checker's temporal-negation and possessive-month counterexamples. Its final repository gate is running in `/tmp/atlas-whiskerflow-final-gate.log`; PR publication, review windows, merge/deployment and fresh playback/deadline E2E remain pending. WhiskerFlow PR 13 remains unmerged.

Atlas final `npm run check:focused` passed on clean 695dbad3: 6,315 tests, five quality gates, 184 seconds wall time. PR #3547 (https://github.com/thatworkagency/atlas/pull/3547) opened 21:46:28 UTC and marked ready by 21:46:55 UTC. First quiet window starts 21:46:55; no actionable feedback observed in the initial poll. Both ten-minute windows and live deployed proof remain required.

The correction protection failure reproduced in an independent ad-hoc-signed, LaunchServices-launched synthetic probe (`/tmp/whiskerflow-protection-probe-result.txt`: write=ok, reopen NSCocoaErrorDomain257). This rules out an XCTest-only launcher issue. Apple Platform Security documents login/logout rather than lock/unlock as the relevant macOS boundary; the earlier lock/unlock suggestion is not a demonstrated remedy. No real correction contents were read or altered by the probe.

Ordinary capture has a separate confirmed resource flaw: retaining all 16kHz Float samples is 2.5344GB for eleven hours before full-length WAV and inference copies. A bounded, disk-backed capture and decode repair is being implemented; the passing buffer primitive test alone does not prove integration or resolve the17GB report. AC8 also still requires an explicit saved-coaching archive and acknowledged deletion; implementation underway. These remain release blockers.

## 22:00 UTC review repair update

Atlas PR3547's review found relative-period direction and multi-date negation movement failures. Five new regression cases failed before repair. Commit4d0df3f6488fbe403e963eb0d6df3b46bac85dfb preserves directional markers and conservatively retains negation order relative to multiple dates. 51 focused tests,106 runtime/transport tests and Convex typecheck passed; same independent checker PASS. Final check:focused passed6,323tests and all5gates (/tmp/atlas-temporal-direction-final-gate.log), then pushed. Both review threads were answered and resolved. Restart quiet windows conservatively at22:00:15UTC (firstends22:10:15,secondends22:20:15), subject to further actionablefeedback. No merge yet.

Native HEAD3457c52 commits the already live-validated meeting CPU/ANE setting and removes the experimental comment. Audio and coaching lifecycle repairs are still uncommitted under independent review. Initial primitive tests did not prove all callsite contracts: checker found Whisper's existing live sample API omits timing segments required by bounded file assembly, and forward-only meeting microphone capture lost the sample-count flow signal. These are blocking and being repaired before the next app bundle. Coach review also requires retiring unresolved deletion tombstones truthfully and isolating local recap deletion by connection.

Actual recording metadata resolves the long-capture uncertainty: WAV2580A62C-25F0-49B0-8DA7-909C1E6FAF58 is16kHzmonoInt16,630,150,397frames,39,384.399812seconds,1,260,300,794audio bytes (afinfo headerinspectiononly). The task-paused capture really lasted10h56m; fullFloat32 expansion is~2.52GB before copies/model allocations. Capture has stopped. The recording is preserved locally, not automatically retried or removed. No claim that this measured the reported17GBpeak.
