# Call coverage and coach upgrades (Phases 2 and 3)

Branch `claude/meeting-library`. All testing on 25 September was silent, by request:
- no audio playback, microphone capture or live calls;
- unit tests;
- text-only model evaluation;
- a read-only CoreAudio probe;
- the debug UI preview with synthetic data.

## Decision: the extension and caption paths are deleted

Jacob asked for WhiskerFlow to be native to the Mac, with nothing else to install. The code involved:
- the Chrome extension (`browser-extension/`);
- its native-messaging helper (`WhiskerFlowMeetBridge`);
- the encrypted browser inbox (`MeetingBrowserInbox`, `MeetingBrowserCapture`);
- the caption reader (`MeetingCaptionCapture`, `MeetingCaptionEvidence`, caption evidence storage).

None of it was ever started by the app. There was no evidence that it improved speaker names: the 15 September caption replay produced 0 named turns, and the extension was never installed. All of it is removed, together with its tests, `script/register_meet_bridge.py` and the bundling steps.

Speaker names still come from the native Accessibility reader and the in-memory visual tile reader, which don't change.

## Call detection

**Signals, all native:**
1. **CoreAudio process objects** (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, macOS 14.2+): which processes are capturing from the microphone. Helpers map to their app by bundle-ID prefix; for example `com.google.Chrome.helper` maps to Chrome. Safari's capture runs in shared `com.apple.WebKit.*` processes and is attributed only to WebKit browsers. WhiskerFlow's own capture is ignored.
2. **Accessibility window and tab titles**, read only for a browser that is using the microphone. The tree walk is bounded (400 nodes, depth 12, 250 ms per element) and skips web content. Titles stay in memory only; the diagnostic log records a fixed event name and the platform, never a title or meeting code.

**Rules** (`CallDetectionRules`, AppSupport, unit-tested):
- **Desktop apps:** Zoom, Microsoft Teams (both bundles), Slack and Webex. The app using the microphone is the call signal.
- **Browsers:** Chrome (all channels), Chromium, Safari, Safari Technology Preview, Edge, Arc, Dia, Brave, Firefox, Vivaldi, Opera and Orion. A call is recognised from a window or tab title:
  - Meet: its code (`abc-defg-hij`) with "Meet";
  - Teams: "Microsoft Teams";
  - Zoom: "Zoom Meeting" or `zoom.us`;
  - Webex: "Webex";
  - Slack: a huddle title.
- **Tab preference:** Chromium's "Microphone recording" tab indicator wins over background call tabs.

**Start and end** (`CallSessionTracker`):
- A call starts after two consecutive 3 s polls, so a sound check or a brief clip doesn't prompt.
- It ends 15 s after its app stops using the microphone. A started call survives an unreadable title while the microphone stays open.

**Prompt.** Every detected call gets the "Record this meeting?" HUD, whether or not it's on the calendar, unless something is already recording:
- the HUD is a floating, non-activating panel, excluded from screen sharing;
- "Not now" isn't asked again for that call;
- "Record" starts a normal recording;
- a prompt-started recording stops by itself when the call ends, and ignores the calendar end time.

The setting is Meeting setup → Calls → "Ask to record when a call starts", on by default. The older opt-in "record scheduled Meet calls automatically" still exists and is off by default. Its description now says that it skips the question.

**Calendar matching** (`CallCalendarMatcher`):
- a Meet code must match the event's join link exactly;
- other platforms match a current event (10 min early to 15 min late) whose join link or location has the platform's host;
- a matched event supplies the title and the Atlas calendar binding.

**Verified silently:**
- 12 rule and tracker tests, plus coordinator and detector tests (prompt once, calendar match, off switch, native signals to events).
- A CoreAudio probe on this Mac read 39 process objects, none using input. That confirms the API works in-process.
- The opt-in in-app probe (`WHISKERFLOW_CALL_PROBE=1 swift test --filter CallSignalProbeTests`) took about 4.7 ms per steady-state poll, off the main thread. Polling every 3 s costs about 0.16 % of one core. Titles are read only while a browser uses the microphone.
- The prompt appears only when recording can actually start, so Microphone and Screen Recording access must already be granted.

**Not verified live**, because no calls could be made:
- the real helper bundle IDs that each app uses while in a call;
- Safari's WebKit attribution;
- Teams and Webex titles;
- Slack clips versus huddles.

These need a quiet daytime check with each app.

## Coach

**Measured directly** (WhiskerFlowCore, unit-tested):
- **Talk share.** You ÷ (you + others), from the separate microphone and Mac-audio tracks. Crosstalk counts for neither side. It needs 30 s of speech, and is shown for the whole meeting and the last 5 minutes.
- **Your turn and monologues.**
  - A turn survives your own pauses of up to 3 s and the others' backchannels under 2 s.
  - It ends when someone else speaks for 2 s, or you're silent for more than 3 s.
  - Turns over 90 s count as monologues and trigger a reminder once per turn.
- **Pace.** Words per minute over the seconds you actually spoke.
  - **Source:** on-device transcription of 20 s windows of your microphone, through the dictation model's background preview path. That path returns nothing when the model is busy, so it never delays a dictation.
  - **Which windows:** only those where you did most of the talking, so remote voices leaking from the speakers aren't counted.
  - **After the meeting:** the transcript's "You" turns replace the live estimate.
- **Reminders** share a 60 s cooldown, in this order:
  1. the planned end;
  2. a break;
  3. monologue;
  4. the existing "much of the last minute";
  5. fast pace (over 175 wpm, at most every 5 min);
  6. talk share of 70 % or more over the last 5 minutes, once there are at least 2 minutes of speech and 5 minutes have passed (at most every 10 min);
  7. the AI tip.
- **Trends.** Each meeting stores a numbers-only `MeetingCoachSummary`, encrypted in its library entry. The Meetings screen shows averages over the last 10 coached meetings: talk share with direction, pace, long turns per meeting, and the longest turn. Summaries are made only when coaching was on.

**Experimental on-device AI tips** (on by default since 26 September, at Jacob's request; they run only on macOS 26 with Apple Intelligence available and can be turned off in the coach panel):
- **Model:** Apple's built-in foundation model, weak-linked, so the app still runs on macOS 14 and 15. It is already on the Mac; WhiskerFlow installs and downloads nothing.
- **Input:** only your own recent words (at most 250, in memory, cleared at the end or on pause) and the goal you typed.
- **Frequency:** at most every 3 minutes, after 60 new words and 2 minutes in.
- **Design:** the model never writes the tip.
  - It answers yes or no, one question per request, fresh session each time: "How does the speaker come across?" (a pick-one tone list, including assertive) and "Is it relevant to their goal?", plus a jargon question.
  - Countable checks run without the model: filler-word rate, vague-commitment phrases, long stretches without a question.
  - WhiskerFlow maps the result to fixed, reviewed wording, so a tip can never quote the meeting, name anyone or invent facts.
- **Rating:** each tip carries "Helpful / Not helpful". The counts are saved with the meeting, so real usefulness can be measured.

**Evaluation** (text only, 16 invented scenarios, 4 of them holdouts written before the last tuning pass; `WHISKERFLOW_COACH_MODEL_EVAL=1 swift test --filter CoachSuggestionEvaluationTests`):

| Approach | Agreement with a sensible coach | Notes |
| --- | --- | --- |
| Free-text tip | 6/8, but it suggested something every time | Nearly always "Invite others in…"; named a person once |
| One category from a list | 3/8 | Anchored on the first category |
| One structured answer with four yes/no fields | 4/12 | "Vague next steps" said yes almost every time |
| Rules only (no model) | 10/16 | Misses tone, drift from the goal, jargon |
| **Shipped: rules + one question per request** | **15/16** | Median 0.69 s, max 1.17 s per check. One false "defensive" on an acronym-heavy outage explanation |

The scenarios are few and written by us, so this shows the approach is plausible, not effective. Real meetings, with the in-app ratings, decide whether the tips earn their place.

## Validation

- **Merge check.** The base branch moved on meanwhile (b5a6abb: onboarding rebuild, SQLite history, recording playback). Applying this work onto it conflicts only in `AppState` (the new paste routing and onboarding set-up), `UIPreview` and `ContentView` (the base now has its own `--ui-destination`). The resolved tree is at `/tmp/wf-merge-check`: it builds and runs 719 tests. The only 3 failures (`CorrectionStoreTests` ×2, `DictionaryStoreTests` migration) reproduce on the untouched base.
- `swift test` on this branch: 578 tests, 10 opt-in skips. The only failure is the existing `CorrectionStoreTests` temp-folder `EPERM` (`corrections.json … Operation not permitted`), in code this branch doesn't touch. It passed in this worktree earlier the same evening, and the 17 September notes record the same environment failure.
- Screenshots, from the debug UI preview (separate bundle ID; synthetic activity, no audio):
  - `2026-09-25-meeting-library/20-call-prompt.png`
  - `21-coach-hud.png`
  - `22-meetings-coach.png`
  - `23-meetings-trends.png` (coach settings and trends)

## Live check, 26 September (06:42–06:57 UTC)

Jacob ran real Google Meet calls with the Meet web app (Chrome's installed web app) while the branch build was installed over `/Applications/WhiskerFlow.app`. His previous build was backed up to `~/WhiskerFlow-backups/`.

**What went wrong first, and the fixes:**
1. **No prompt.** The microphone signal was right (`com.google.Chrome.helper`), but the reader looked only at Chrome's own windows. The call was in the Meet web app (`com.google.Chrome.app.kjgf…`, window owner "Google Meet"), off the current Space. Accessibility lists only current-Space windows and exposed no tab strip; `AXManualAccessibility` is unsupported by this Chrome.
   - **Fix:** browser web apps (Chromium `<browser>.app.<id>`, Safari `WebApp`) now count as their browser (`CallDetectionRules.titleSourceOwner`).
   - **Fix:** window names now also come from the window server (`CGWindowListCopyWindowInfo`, all Spaces, using Meeting Mode's Screen Recording access), alongside Accessibility tab titles.
   - **Result:** after the fix, the call was detected 3.3 s after launch.
2. **Content-free detection events were dropped.** The local diagnostic log keeps only allowlisted events.
   - **Fix:** `call_detection_started`, `call_detected`, `call_ended` and `call_unrecognised` are now allowlisted. Their fields are counts, `accessibility` true/false, `platform` and `source` (app, browser or webkit). A unit test checks that titles and bundle IDs are dropped.
3. **A recording stopped early.** Jacob's Safari Meet test (Safari's WebKit capture from 06:52:23) ran alongside the Chrome call. The prompt switched to that second call, the recording followed it, and it stopped at 06:53:15 when that call went quiet, although the Meet call carried on.
   - **Fix:** a prompt-started recording now stops only when no detected call remains.
   - **Fix:** a second call no longer replaces a prompt already showing.

**Worked:**
- prompt, then Record;
- auto-stop when the Meet ended (06:56:14);
- both recordings delivered (audio removed, encrypted library entries kept);
- transcription quality was good by Jacob's account.

**Confirmed by Jacob:**
- a Google Meet in Safari was detected and recorded;
- a Google Meet in Chrome went end to end, from the prompt to delivery in Atlas.

**Still open for Monday:**
- a Slack huddle;
- a Meet with other people, for talk share, turns, pace and AI tips on real speech;
- why `call_detected` was logged twice at 06:51:57. The `source` field now logged should explain it.
