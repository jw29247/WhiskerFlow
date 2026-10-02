# WhiskerFlow 2.0.0: release brief

Branch `codex/whiskerflow-2-assistant` against `origin/main` (`b04a2c7`, the 0.8.7 release).

| | |
| --- | --- |
| Version | 2.0.0, build 22 (from 0.8.7, build 21). Set by `script/bump_version.sh` |
| Ahead of main | 66 commits; main has nothing the branch lacks |
| Size | 320 files, +38,950 / −3,501 lines. About half is tests and validation records |
| Platform | Unchanged: Apple Silicon (arm64), macOS 14 and later |
| Signing | Developer ID team G9U38P58ZY. The signed 2.0.0 candidate passes `verify_upgrade_identity.sh` against the installed app, so permissions carry over |
| Tests | CI (macOS 26, Xcode 26.6) on the review-fix head: `swift test` ran 784 tests, 0 failures, 15 opt-in skips. `test_version_source.sh`, `test_bundle_app.sh` and `test_upgrade_identity.sh` pass |

## What's new for users (release notes)

> **WhiskerFlow 2.0**
> - **Meetings.** WhiskerFlow notices calls in Zoom, Teams, Slack, Webex and Google Meet (in any browser) and asks whether to record. Transcripts are made on your Mac and sent to Atlas, with a private meeting library, notes, bookmarks and Markdown export. Speakers show as You and Them, with names from Google Meet where they're available.
> - **A private meeting coach.** Talk share, speaking pace and long monologues, with gentle reminders and trends over time, plus experimental on-device AI tips.
> - **Dictate in your own language.** Choose your language once, and WhiskerFlow types it in English, translated on your Mac. Parakeet covers 25 European languages, and Apple's on-device dictation covers 15 more, including Hindi, Arabic, Japanese and Chinese.
> - **Faster and simpler transcription.** Everything now runs on Parakeet, and Whisper is gone. Its downloaded models are deleted, which frees several GB.
> - **The team leaderboard.** Words, time saved, streaks and meetings, across everyone at the company, via Atlas. Only counts are shared, never text.
> - **A Dictionary that learns.** It picks up your corrections and works per app category (email, chat, documents).
> - **History and Insights.** Choose how long history is kept, and see lifetime stats. Recordings are kept for 14 days so you can play them back or re-transcribe them.
> - **Smarter around your audio.** Media pauses while you dictate (only when something is actually playing), and Bluetooth headphones no longer drop to call quality because of WhiskerFlow.
> - **New setup and Atlas sign-in.** A guided first-run setup, and WhiskerFlow now needs you to sign in with Atlas.

## What changes on an existing Mac at first launch

| Change | Effect | Reversible? |
| --- | --- | --- |
| History moves from `transcripts.json` to `transcripts.sqlite` | The JSON is kept as `transcripts.migrated-<ts>.json` | Downgrading to 0.8.x shows empty history |
| Whisper engine choice becomes Parakeet (Apple Speech on Intel). Whisper CLI settings are dropped | `Application Support/WhiskerFlow/Models` Whisper folders are deleted | Models would re-download, but 2.0 has no Whisper |
| Corrections become the Dictionary | One-time migration from the old vocabulary | Old keys left in place |
| Echo-cancellation setting removed | Fewer mic hangs | n/a |
| Meeting Mode and the coach switch on once | Recording still waits for "Record this meeting?" | Users can switch them off |
| Atlas sign-in required | The app shows only the sign-in screen, and dictation won't start, until the user signs in | n/a |
| First leaderboard report | Sends the full day-by-day history of counts | n/a |
| Setup | Existing users are marked as done, so they **don't** see the new language step | Settings → Dictation → Language |

## Must happen before anyone gets 2.0

1. **Deploy Atlas PR [#3697](https://github.com/thatworkagency/atlas/pull/3697)** (merged 2 October; confirm it's live). Without it, sign-in fails for Finance and Contractor roles (they're locked out of dictation entirely), and the leaderboard shows "not available".
   - After deploying, check that custom role presets have WhiskerFlow access.
   - Decide whether Contractors appear on the board.
2. **Merge PR #13 to `main`.** Sparkle reads `appcast.xml` from `main`, so nothing reaches users until the release commit is there.
3. **Rotate the Atlas staging admin key** that leaked into a session log (see the leaderboard notes).
4. **Make the release Mac able to build and sign 2.0.**
   - Install Xcode 26.6, as CI uses, and select it with `sudo xcode-select -s /Applications/Xcode.app`. The code needs Swift 6.3. On 2 October the Mac had only Command Line Tools with Swift 6.2 and a mismatched SDK, and `swift build` failed.
   - Check that `security find-identity -v -p codesigning` lists the Developer ID Application certificate. On 2 October it listed none.

## Review fixes (2 October)

Nine review comments on PR #13: eight fixed, one already handled by later commits.

| Fix | Effect |
| --- | --- |
| Interrupted recordings count as a source gap | A session cut off by a crash or quit is never marked fully covered in Atlas (0.8.7 behaviour) |
| "Not now" is honoured by scheduled capture | Declining the prompt for a calendar Meet call no longer lets the next schedule poll record it |
| Long notes reach Atlas in full | Notes over 200 characters go as numbered bookmark parts; a note counts as sent, and can be deleted by retention, only when every part is in Atlas |
| Audio is kept until the library copy is saved | A full disk or unwritable library no longer loses the local transcript; delivery retries instead |
| Reused Meet links match the current event | Back-to-back meetings in one room get the right title and calendar event |
| Call-end detection follows a prompt-started recording | Turning off "Ask to record" mid-call no longer leaves the recording running after the call |
| A failed Keychain read is retried | A transient Keychain error no longer signs the user out (and blocks dictation) until restart |
| Retried assistant captures keep their purpose | A failed quick capture becomes its draft on retry, not dictation. History's SQLite schema goes to v2; databases from earlier 2.0 test builds are upgraded in place |

## Release steps (from `main`, after the merge)

```bash
DEVELOPER_ID=70C7AE332EB4AB53C5DF2D22E46302FB6E3A2EA2 \
NOTES="WhiskerFlow 2.0: meetings, a private coach, dictation in your own language, the team leaderboard, and Parakeet everywhere." \
script/notarize.sh
gh release create v2.0.0 dist/WhiskerFlow-2.0.0.dmg dist/WhiskerFlow-2.0.0.zip \
  --title "WhiskerFlow 2.0" --notes-file <release notes above>
git add Resources/Info.plist appcast.xml Casks/whiskerflow.rb && git commit -m "release: publish WhiskerFlow 2.0.0 update feed" && git push
```

**Release gotchas:**
- `DEVELOPER_ID` must be the hash above, because the keychain holds two identically named certificates.
- The Sentry dSYM upload needs `SENTRY_AUTH_TOKEN`. Earlier releases skipped it.
- `.github/workflows/release.yml` only verifies; it doesn't publish.

## Verified, and not

**Verified on Jacob's Mac (signed builds installed in /Applications):**
- Meet calls in Chrome and Safari: prompt → record → transcript in Atlas.
- Slack huddle prompt.
- Parakeet meeting transcription, 100× real time on a recorded meeting.
- Input-only mic capture: two dictations on the C920 with the Soundcore connected, and no Bluetooth call-mode switch.
- Language detection and translation: Jacob confirmed it works.
- Media pause with nothing playing: Now Playing is checked first, and nothing is pressed.

**Not verified:**
- **Real users:** a long day with the new mic capture, and a real call with the new You/Them labels.
- **Leaderboard and sign-in against a deployed Atlas.**
- **macOS 14 and 15:** the app has never been launched there. Translation and FoundationModels are weak-linked, and Apple dictation and translation need macOS 26.
- **Translation details:** the translation download sheet, and whether `.highFidelity` stays on the Mac with no network.
- **Mixed engines:** non-English dictation with Apple's dictation model on a second Mac.

**Known issues to decide on:**
- Meeting `CF283DF9` (87 minutes, 1 October) has been stuck uploading. Meeting audio is uploaded uncompressed, about 690 MB an hour.
- International staff who already use WhiskerFlow won't be asked for their language, because existing installs skip setup. Should 2.0 ask everyone once?
- Branch `t3code/whiskerflow-2-ui-build`: 80 commits from 6 weeks ago (two-pass dictation, a transcription bake-off). None of it is in this release, so confirm it's superseded.
- The in-app version is now 2.0.0, so Sparkle won't offer 0.8.x builds to anyone on 2.0.
