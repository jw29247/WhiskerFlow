# Meeting Mode repair — 4 September 2026

## Reproduced failures

- Atlas pairing was valid: an authenticated read-only schedule request returned HTTP 200 and 50 rows. The app returned no schedule at all when automatic recording was off. The new coordinator regression failed with 0 rows instead of 1 before the fix.
- Retained recordings had no Atlas references or uploaded chunks. Local model preparation ran before any upload. A replay of the retained 25-second session stalled in CoreML/Neural Engine preparation; the bounded diagnostic later reported the 180-second preparation deadline.
- A fresh physical capture found a second failure: the AirPods input started but delivered no microphone buffers. It produced four system chunks, no microphone/mixed chunks, and was correctly sent as partial.
- Review identified an existing lost-response retry hazard: replaying Atlas completeRecording after accepted finalize can downgrade coverage before duplicate finalize returns early.

## Changes

- Fetch the calendar independently of automatic recording. Preserve recording/upload progress during polling and configuration refresh.
- Require live microphone buffers before announcing recording; fall back to the built-in microphone if the selected/default transport starts without audio. Report actual capture errors.
- Upload encrypted audio and playback before local transcription. Missing source tracks remain explicitly partial; available source audio can still be transcribed.
- Keep encrypted audio-delivery receipts and transcript checkpoints, bound to the session. Retries skip accepted recording completion and reuse transcription. Concurrent attempts for one session are excluded.
- Validate Atlas playback, segment and finalization acknowledgements before treating delivery as complete. Add retry and Open in Atlas controls.
- Use the same pinned Whisper meeting model on CPU/GPU to avoid the observed ANE preparation stall. Coalesce concurrent meeting model preparation and bound the wait. Dictation model compute settings are unchanged.
- Clear the scheduled-stop task before stopping capture so it does not cancel its own delivery.

## Live acceptance

The signed local app used the existing WhiskerFlow identity and pairing. A 30-second capture used the actual microphone and ScreenCaptureKit system-audio path, including spoken verification content. Existing Mac output was also captured, as expected for Meeting Mode.

Successful capture session: `6AA24429-3EC5-4B49-AD56-75E955359198`.

- Duration: 31,940 ms.
- Four microphone, four system and four mixed chunks.
- No detected source gap.
- Atlas meeting: https://atlas.thatworks.agency/meetings/vh8fqr0q7zjtayxea0bhma996n8drh0n
- Atlas artifact: `rx8wn0r0fvemh5ve43nmzxp5498drw2n`.
- Native delivery finalized successfully at 21:32:57 UTC.
- Authenticated Atlas UI showed **covered**, **Speaker-labelled local transcript complete**, and newly generated meeting notes containing the verification discussion.
- The Atlas audio control was present. Playback start was not independently verified through the browser automation surface.

The initial partial test also reached Atlas with a transcript and notes. The two agent-created test sessions and metadata reports were moved into `.build/meeting-verification/accepted` after server acceptance, preserving encrypted local evidence without replaying them in normal recovery. Original user recordings remain in the normal recovery store. One original short retained recording was uploaded; its first ANE transcription attempt timed out, so its local audio remains recoverable.

## Verification and scope

- `swift test --skip DictationPerformanceTests`: **266 tests, 2 intentional skips, 0 failures**. Includes calendar/manual mode, microphone selection, audio delivery despite model failure, encrypted transcript reuse, accepted-but-lost finalize response, incomplete playback and malformed finalization acknowledgements.
- Developer ID signed debug bundle passed codesign validation and the live capture above.
- Focused independent code review found no blocking defects in the final delivery receipt or scheduled-stop changes.
- `git diff --check` passed.
- Changes are local and uncommitted alongside the separate UI/performance work. No Atlas code, credential changes or public release were made by this repair task.

## Explicit diagnostic entry points

Debug builds support `--repair-meeting=<session UUID>` for a single retained session, and `--verify-meeting-capture` for a 30-second live microphone/system-audio verification. They bypass ordinary startup/recovery and retain the session after completion. They are excluded from release builds. Debug builds do not start Sparkle, so an unreleased local candidate cannot replace itself with an older public UI. Metadata-only JSON reports are written to the user's temporary directory. Never run a live diagnostic as part of automated unit tests.

The final signed local bundle is `.build/debug/WhiskerFlow 2.app`. It was opened normally after quitting the old app and visual-only preview. Its Meetings screen showed **Connected to Atlas**, the live upcoming calendar while **Automatic recording is off**, and recovery progress for retained recordings. Sparkle is disabled in debug builds; the installed public app bundle was not replaced.
