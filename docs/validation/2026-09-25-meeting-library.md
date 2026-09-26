# Meeting library, notepad and mid-meeting dictation (Phase 1)

Branch `claude/meeting-library`, based on `codex/whiskerflow-2-assistant` at f71b7d8.

## What changed

- **The library keeps the transcript after delivery.** A `MeetingLibraryEntry` (AppSupport) holds:
  - title, times and status;
  - the speaker-labelled turns;
  - notes, bookmarks and Dictated spans;
  - the private coach recap;
  - Atlas insights, when Atlas returns them.

  It is sealed with AES-GCM using the existing meeting-recording key. The file is authenticated to its session ID, has mode 0600, and lives in `MeetingLibrary/<session>.wfmeeting`. Raw audio and the transcript checkpoint are still removed after a successful delivery, as before. The transcript is written to the library first, and the write queue is flushed before `removeSession`.
- **Retention setting** (Meeting setup → Transcripts on this Mac): forever, 1 year, 90 days (the default), 30 days, or delete after delivery. Two cases are never removed: a meeting that hasn't been delivered, and a meeting with a note that hasn't reached Atlas. Until then, the local copy is the only copy.
- **Meetings screen:** "Your meetings · on this Mac" lists in-progress meetings first, then newest. Each row shows one of Recording, Uploading, Transcribing, Waiting to send, Delivered, or Failed. Failed and waiting meetings have a per-meeting Retry, which releases that recording's manual hold and delivers it. Recordings retained from before this change get an entry when the recovery scan runs. The scan waits for the stored library to load first, so saved entries are never replaced.
- **Detail view:**
  - speaker-labelled transcript with a timestamp on every line;
  - ⌘F search with ⌘G / ⇧⌘G, a match count and highlighting;
  - "Moments" chips for notes, bookmarks and Dictated spans, which jump to and highlight the row;
  - inline note, bookmark and Dictated rows;
  - the private coach recap (kept out of exports);
  - Copy as Markdown (⇧⌘C) and Export Markdown…;
  - Open in Atlas;
  - Delete from this Mac, for delivered meetings only.
- **Notepad** in the live meeting card and in the live detail view. Each note is stamped with elapsed time on the capture timeline, the same origin as the transcript turns. Notes are stored encrypted with the meeting. After delivery they go to Atlas through the existing bookmark transport (`bookmarkSync` → `notetaker.assistant.addBookmark`), with the note as the label.
- **Dictated marker:** push-to-talk during a recording opens a span, and releasing closes it. Stopping the recording closes any open span. The transcript shows a "Dictated" row, and a "Dictated" badge on the user's own-microphone turns that are at least half inside the span. Remote speakers who talk over a dictation are never marked.
- **Atlas insights:** there's a `notetaker.getMeeting` client and parser, used only when a valid `wm1_` device reference is known (see gap 1). Otherwise the detail view says the summary is in Atlas. No summaries are generated on this Mac.

## Dictating during a meeting: what happens today

There was a live check on 25 September at 20:49–20:56 BST. The signed candidate ran under an isolated `CFFIXED_USER_HOME`, and Chrome Google Meet call `sct-vhvv-mvi` was joined.

1. **Crash.** Within 15–35 s of Meet starting or changing the mic (joining, turning the camera off), the app aborted with SIGABRT. The stack runs `AudioCaptureService.prepareCapture` → `buildCapture` → `AVAudioNode.installTapOnBus`, which raises an `NSException` when the hardware format changes between the format query and the install. Swift can't catch it. It happened twice, before any recording or dictation (crash reports `WhiskerFlow-2026-09-25-205002.ips` and `-205119.ips`). It comes from the prepared-engine path added in 5f4ede4, not from this branch.
2. **Deadlock.** After the crash fix, a meeting was recording and someone pressed fn. The main thread blocked for good in `AppState.beginRecording` → `setVoiceProcessingEnabled` → AudioDSP `shared_mutex.lock`, because a background `prepareCapture` was building a second voice-processing unit on the engine queue at the same moment. The UI froze. Meeting chunks stopped at 30 s (7 chunks), even though capture kept running. So today, push-to-talk during a meeting can freeze the app and silently cut the recording short.

### Defined behaviour and fixes

- **The mic is shared.** The meeting keeps its own raw microphone engine, and dictation opens its own engine on the same device. Neither stops the other.
- **Engines are built one at a time.** Every capture engine is now built on the single serial `engineQueue`, so a press waits for an in-flight preparation instead of racing it. The meeting and dictation instances share that queue.
- **A changing format fails the build, not the app.** `installTap` runs inside `WFPerformCatchingObjCException` (new `WhiskerFlowObjCSupport` target). An Objective-C exception becomes `AudioCaptureServiceError.invalidInputFormat`. Only the exception name is kept, never its reason. A failed preparation is simply skipped, and a failed press shows the normal capture error.
- **The transcript marks the span as Dictated.** The dictated words stay in the meeting transcript, because they were spoken aloud in the room or call.

Not yet verified live: a push-to-talk round trip during a recording with both fixes in place (see "Live acceptance").

## Atlas `POST /api/notetaker` inventory

Read from Atlas `origin/main` 046214668 (2026-09-25), in `packages/convex/convex/http/notetaker.ts`, `meetings/assistant.ts`, `meetings/assistantContract.ts` and `meetings/workspace.ts`. Nothing was changed in Atlas.

| Tool | Arguments | Returns |
| --- | --- | --- |
| `notetaker.ping` | — | ok |
| `notetaker.schedule` | `fromMs`, `toMs`, `limit` | calendar intents (`eventId`, `title`, `startMs`, `endMs`, `meetingUrl`, `location`, `existingMeetingId`, `overlapsPrevious`) |
| `notetaker.heartbeat` | `appVersion`, `permissionState`, `diskState`, `captureState`, `lastFailureReason?` | ok |
| `notetaker.createMeeting` | `externalRef`, `captureSessionId`, `contextType` (sales/client/general), `dealId?`, `clientId?`, `contactId?`, `calendarEventId?`, `externalCalendarEventId?`, `meetingUrl?`, `title?`, `occurredAtMs?` | `{ meetingId` (raw Convex ID), `created }` |
| `notetaker.prepareRecording` | `meetingId`, `captureSessionId`, `tracks[{track, expectedChunkCount}]`, `sourceManifestHash?`, `playbackChunkCount?` | `{ artifactId }` |
| `POST /api/notetaker/upload` | encrypted chunk body; `x-recording-*` headers (`kind=playback` for the mixed playback copy) | 2xx |
| `notetaker.completeRecording` | `externalRef`, `artifactId`, `durationMs`, `trackChunkCounts`, `hasSourceGap`, `missingTracks`, `canonicalChecksum?`, `sourceManifestHash?`, `modelVersion?` | `{ completed, duplicate, status }` |
| `notetaker.completePlayback` | `externalRef`, `artifactId` | `{ completed / duplicate }` |
| `notetaker.appendSegments` | `externalRef`, `meetingId`, `segments[{speakerLabel, speakerKey?, speakerDisplayName?, speakerResolution? ∈ self/diarized/unknown, speakerConfidence?, speakerProvider? ∈ whisperkit/speakerkit, text, startMs?, endMs?}]` | `{ appended, duplicate }` |
| `notetaker.finalize` | `externalRef`, `meetingId`, `artifactId?`, `status` (done/failed), `transcriptionState?` (completed/failed), `providerNotes?`, `failureReason?` | `{ finalized }` |
| `notetaker.getMeeting` | `contractVersion: 1`, `meetingId` (**`wm1_` device reference only**), `transcriptCursor?`, `transcriptLimit?` (1–200) | `meeting` (title, occurredAtMs, durationMs, processingState), `recording` (status, transcriptionState, durationMs, hasSourceGap, missingTracks), `transcript` (segments, nextCursor), `notes` (status: not_started/processing/suggested/failed; summary, markdown, discussionHighlights, outcomes, priorities, openQuestions, risks, nextActions[{text, owner?, due?}]), `intelligence?` (clientSafeSummary, decisions, risks, openQuestions, proposedActions) |
| `notetaker.retryMeetingNotes` | `contractVersion: 1`, `meetingId` (`wm1_`) | retry receipt |
| `notetaker.getTeamVocabulary` | `mode`, `sinceVersion?`, `limit`, `cursor?`, `clientId?` | vocabulary page |
| `notetaker.corrections.*` | submitObservation, submitReviewCandidate, editReviewCandidate, approveReviewCandidate, discardReviewCandidate, setPersonalCandidateEnabled, undoObservation, deletePersonalCandidate, rejectSharedCandidate | correction receipts |
| `notetaker.assistant.*` (`contractVersion: 1`) | rewrite, getResult, listClientProfiles, getClientProfile, captureDraft, listDrafts, getDraft, discardDraft, **addBookmark** (`requestId`, `meetingReference`, `offsetMs`, `label?` ≤ 200 chars), listBookmarks, requestCoach, deleteCoach | per-tool receipts; addBookmark returns `{ bookmarkReference, offsetMs, createdAtMs }` |

### Backend gaps (Atlas changes WhiskerFlow can't make)

1. **The summary and action items can't be read back.** `notetaker.getMeeting` returns exactly the summary, decisions, next steps and risks the library would show. But it accepts only the opaque `wm1_` reference, and no tool the device can call returns one: `createMeeting` returns the raw Convex ID. The reference is already computed in `ingestCreateMeeting` via `ensureMeetingDeviceReference` (`meetings/notetaker.ts` around lines 418/438/511). Either option would light the feature up without further client work:
   - return it as `meetingReference` from `createMeeting` (WhiskerFlow already parses that field, and validates it before use);
   - or accept the raw-ID bridge that `assistant.resolveMeeting` already applies (`meetings/assistant.ts` lines 110–146).
2. **There's no typed-note tool.** Notes use `addBookmark` labels, which are capped at 200 characters. Longer notes are shortened in Atlas with "…"; the full text stays on the Mac. Atlas needs `addNote` (longer text), or a `kind` on bookmarks so notes and bookmarks can be told apart.
3. **Segments lose provenance and can't carry markers.** `appendSegments` drops `speakerResolution` google_meet/manual and `speakerProvider` google_meet/manual through literal filters. It has no per-segment field for a Dictated marker, so Atlas can't show "Dictated".
4. **Bookmarks and notes after the recording's end are rejected.** `addBookmark` requires exactly one artifact and `offsetMs ≤ artifact.durationMs`. Notes are clamped to the recording's duration before they're sent.
5. **There's no device read of meetings by capture session.** The library is the only on-device index; a reinstall can't rebuild it from Atlas.
6. **There are no personal to-dos.** `nextActions` carries an optional `owner` but has no "mine" flag, so "personal to-dos" can't be separated from team next steps.

## Validation

- `swift test`: 542 tests, 0 failures, 9 existing opt-in skips. New tests:
  - `MeetingLibraryTests` (16), covering retention, timeline ordering, the Dictated rule, anchors, search, Markdown, the insights parser, the `wm1_` format, decoding, and encrypted store round trip, permissions and session binding;
  - `MeetingLibraryCoordinatorTests` (8), covering delivery keeping an encrypted transcript while deleting audio, a relaunch reload, note sync through the bookmark path, delete-after-delivery waiting for notes, failed and held versus waiting states, per-meeting Retry, the recovery scan not replacing saved entries, and `getMeeting` never being sent a raw ID;
  - `ObjCExceptionShimTests` (2).
- Screenshots, from the debug UI preview with invented sample data (separate bundle ID `agency.thatworks.WhiskerFlow.library-preview`; no audio, network or production state). They're rendered by the app's own `--debug-window-snapshots` hook, which is DEBUG-only and needs no Screen Recording permission:
  - `2026-09-25-meeting-library/03-library-list.png`: status list with Retry;
  - `04-detail.png`: speakers, timestamps, moments, inline note, Dictated row and badge;
  - `05-search.png`: ⌘F with 5 matches highlighted;
  - `06-bookmark-jump.png`: bookmark chip jump;
  - `07-recording-notepad.png`: live notepad.

## Live acceptance: passed (25 September, 21:30–21:36 BST)

A signed candidate, with both mic fixes, ran from an isolated `CFFIXED_USER_HOME`. The user's running build was quit for the test with their approval and relaunched afterwards.

1. The candidate joined real Google Meet call `czw-xsou-ptv` in Chrome (work profile) and turned the camera off.
2. A manual recording started at 21:30:26. Two synthetic voices (`say`) played through the MacBook speakers.
3. A typed note was stamped at 0:23 ("Noted at 0:23") and a bookmark at 0:24.
4. Push-to-talk was held for 0:36–0:40 (synthetic fn events) while TextEdit was frontmost:
   - The app stayed responsive and the meeting kept recording (no deadlock).
   - Dictation transcribed in 82 ms and saved to history, but the paste failed: the candidate has no Accessibility grant (unrelated to this change).
5. The recording stopped at 1:25. The library showed Uploading, then Delivered at 21:34:44. Atlas meeting `vh84gvw6sjj1p0gfpf6rd26kdd8f24ga`.
6. After delivery:
   - the chunk directory was empty (audio deleted);
   - the library file (2,404 bytes, mode 0600) contained no transcript or note plaintext;
   - the note and bookmark showed "In Atlas".
7. The detail view showed:
   - Speaker 1 and Speaker 2 turns with timestamps;
   - inline Note, Bookmark and Dictated rows;
   - a "You · Dictated" line at 0:36 with the dictated sentence;
   - Open in Atlas.
8. After a normal quit and relaunch, the meeting was listed as Delivered with the same transcript, note, bookmark and Dictated marker. Copy as Markdown produced the expected document; the clipboard was restored afterwards.

Screenshots: `10-e2e-live-meet-detail.png`, `11-e2e-after-restart-list.png`, `12-e2e-after-restart.png`.

Limits:
- The voices were played from the Mac's speakers, so speaker labels reflect acoustic pickup. The last turn, a remote voice, was labelled "You". This test says nothing about speaker accuracy.
- The call had no other participants, so Meet names weren't exercised.
- The dictated text itself was partly echo-cancelled ("Remind me the onboarding deck is the morning."), because it was the Mac's own playback.
