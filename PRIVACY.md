# WhiskerFlow privacy

Last updated: 22 November 2026. Describes WhiskerFlow 2.1.0.

WhiskerFlow is That Works' internal dictation and meeting-recording tool for
macOS. That Works is responsible for it. Questions about this page or about
your data go to That Works.

This page describes what the software does. It is not a legal statement.

## In short

- Dictation is transcribed on your Mac. Dictation audio and transcripts stay
  on your Mac.
- You must sign in with a That Works Atlas account before WhiskerFlow will
  dictate.
- Meeting recordings and their transcripts are uploaded to Atlas.
- The team leaderboard on Atlas shows colleagues your name and your daily
  counts. It never shows any text.
- WhiskerFlow sends no telemetry, analytics or crash reports. Its diagnostic
  logs stay on your Mac.

## What stays on your Mac

Unless a section below says otherwise, everything here is kept in
`~/Library/Application Support/WhiskerFlow` and never leaves your Mac.

### Dictation audio

Each dictation is recorded as an audio file in the `Recordings` folder.

- By default WhiskerFlow keeps the audio of your 25 most recent successful
  dictations for up to 30 days, and deletes older audio. The transcript text
  can outlive its audio.
- **Settings → History → Keep recordings for 14 days** (off by default) also
  keeps the audio of every dictation from the last 14 days.
- Audio of a dictation that failed to transcribe is kept so you can retry it,
  until that entry leaves History.
- Audio files that no History entry refers to (for example after a crash) are
  deleted once they are 30 days old.

### Transcripts and History

Transcripts are kept in `transcripts.sqlite`. Each entry holds the text, the
recogniser's raw text, the time, the length, the engine and language used, and
the category of app you dictated into (for example "Messages" or "Code"), not
the app's name.

Choose how long History is kept in **Settings → History** or on the History
screen: forever, 1 year, 90 days (the default), 30 days, 7 days, 24 hours, or
"Don't save history".

- Older entries, and their audio, are deleted automatically.
- With "Don't save history", no transcript is saved. The latest dictation stays
  in memory for a few minutes so you can copy it. Failed recordings are still
  kept for 24 hours so you can retry them.
- The retention setting covers History and dictation audio only. It does not
  cover Insights, the Dictionary, meetings, or the backups described next.

**Backups of unreadable history.** If WhiskerFlow finds its history file
damaged, it moves it aside as `transcripts.corrupt-<number>.sqlite` (or, for
history from older versions, `transcripts.corrupt-<number>.json`) in the same
folder and starts a new history. These backups may be the only copy of your
old transcripts, so WhiskerFlow never deletes them and the retention setting
does not apply to them. Delete them yourself if you don't need them. Damaged
Dictionary and meeting files are likewise left in place, never overwritten.

### Dictionary and learned corrections

Your Dictionary (`Dictionary/dictionary.json`) and learned corrections
(`Corrections/corrections.json`) are kept until you delete them.

With **Learn from my corrections** on (the default, in the Dictionary screen),
WhiskerFlow briefly reads the text field you pasted into, before and after
your edit, to learn names and fixes. Only the corrected words are saved, not
the surrounding text.

### Insights

Insights (`insights.sqlite`) keep counts only: per hour, the number of
dictations, words and seconds spoken, and which app and engine you used
(the app is recorded by its identifier, for example `com.apple.mail`). Never
any text. Insights are kept whatever the History setting, until you choose
**Reset insights** in Settings → History or on the Insights screen. Daily
totals derived from them are sent to the leaderboard (see below).

### Settings

Your settings are kept in macOS preferences for `agency.thatworks.WhiskerFlow`.
They include a copy of the next week's meeting schedule from Atlas (see
below). Your Atlas sign-in token and the key that encrypts meeting files are
kept in your login Keychain.

### Meetings on your Mac

While a meeting is recorded, its audio is written in encrypted pieces to the
`MeetingRecordings` folder. They are deleted once the recording and transcript
have reached Atlas and the transcript is saved in your meeting library.

The meeting library (`MeetingLibrary`, encrypted) keeps each meeting's
transcript, your notes and bookmarks, and the private coach summary. Delivered
meetings are kept for 90 days by default. Change this in **Settings → Meetings
→ Keep delivered transcripts**: forever, 1 year, 90 days, 30 days or "Delete
after delivery". A meeting that has not reached Atlas yet, or whose notes
have not, is never deleted by this setting, because the local copy is the
only one.

The meeting coach runs on your Mac. Its state is kept in
`MeetingAssistant/private-meeting-assistant.json`.

### Assistant

Assistant drafts, writing-style choices, client terms and saved coaching are
kept in `Assistant/assistant.json`. They leave your Mac only when you send
them (see Atlas below).

### Diagnostic logs

WhiskerFlow writes diagnostic logs to `~/Library/Logs/WhiskerFlow`:
`diagnostics.jsonl` (with up to two older files, about 2 MB each) and, when the
app stalls, short stack traces in `stacks`. They record timings, resource use
and error codes, never audio or transcript text. They are never sent anywhere.
The app also writes to the macOS system log.

### On-device models

- **Parakeet** (the default dictation engine) runs on your Mac. Its model is
  downloaded once (see Hugging Face below) and kept in
  `~/Library/Application Support/FluidAudio/Models`.
- **Cleanup** (off by default, Settings → Cleanup) runs the Gemma 4 E2B model
  on your Mac after transcription. You download the model yourself from that
  screen; it is kept in `Models/Cleanup`. Your text is processed on your Mac.
- **Translation into English** of dictation in another language uses Apple's
  on-device translation.
- **Coaching suggestions** use Apple's on-device model where macOS offers it.

## What is sent, to whom and why

### Atlas (That Works)

Atlas is That Works' own system, at `https://atlas.thatworks.agency`.
Every request carries your device token, which tells Atlas who you are.

**Sign-in.** Signing in opens Atlas in your browser. Atlas then gives
WhiskerFlow a device token, which is kept in your Keychain. Until you sign in,
WhiskerFlow will not dictate.

**Status check.** While you are signed in, WhiskerFlow tells Atlas once a
minute the app version, whether Microphone and Screen Recording permission are
granted, whether disk space is low, whether a meeting is recording or
uploading, and the code of the last meeting error. No audio or text.

**Meeting schedule.** While you are signed in, WhiskerFlow fetches your next
seven days of meetings from Atlas once a minute (title, times, meeting link
and location), whether or not automatic recording is on. It uses them to
name recordings and, if you turned it on, to start automatic recording.

**Meeting recordings and transcripts.** When a meeting recording ends,
WhiskerFlow uploads it to Atlas: the audio from your microphone, the audio
from your Mac (the other participants), and a mixed copy for playback. It then
transcribes the meeting on your Mac and uploads the transcript, labelled by
speaker, with the meeting title and time and your typed notes and bookmarks.
If you are offline or not signed in, the upload waits and retries. WhiskerFlow
later fetches the notes Atlas writes for the meeting.

**Assistant.** Assistant requests reach Atlas only when you ask:
- Rewrite previews send the text you selected, and any instruction, to
  Atlas AI. Meeting preparation sends your goal and agenda. Both need **Use
  Atlas AI when I request it** (off by default); with it off, preparation is
  done on your Mac. Atlas passes these requests to its AI provider.
- **Review latest meeting** asks Atlas AI to review a meeting already on
  Atlas, sending your goal with it. In 2.1.0 this button works even when the
  Atlas AI switch is off.
- **Send** on a draft saves its title and text to Atlas as a private draft.
- The client list and a client's vocabulary are downloaded when you refresh
  them or pick a client.

**Shared glossary.** WhiskerFlow downloads the agency glossary (client names
and terms) when it starts and every 4 hours. The request contains no text or
personal data. The last copy is kept in `shared-vocabulary.json`.

**Leaderboard.** Every 15 minutes, and when you open the leaderboard,
WhiskerFlow sends Atlas your daily totals: words, dictations, seconds spoken,
estimated time saved, meetings recorded and meeting minutes. The first report
sends every day Insights holds. Never any text. Colleagues with leaderboard
access see your name, picture and these counts, plus your streaks. There
is no switch to turn this off in 2.1.0. Pictures on the board are loaded from
the address Atlas gives for each person.

### Apple

- **Speech assets.** For languages Parakeet does not cover, WhiskerFlow uses
  Apple's on-device dictation model, which macOS downloads from Apple the first
  time you use that language. Translation languages are downloaded from Apple
  the same way, when you choose to download them in Settings.
- **The on-device rule.** The Apple Speech engine only runs where macOS can
  recognise the language on your Mac. If it can't, WhiskerFlow refuses rather
  than letting macOS send the audio to Apple. This rule covers dictation audio.
  It does not stop macOS itself contacting Apple to download speech or
  translation assets.

### Hugging Face

WhiskerFlow downloads models from `huggingface.co`:
- the Parakeet dictation model, the first time you dictate;
- a small vocabulary model, only if Dictionary hints for Parakeet are on
  (off by default; 2.1.0 has no control for it in Settings);
- the Cleanup model, only when you choose to download it.

These downloads send nothing about you except what any download does (your IP
address).

### GitHub (updates)

WhiskerFlow checks for updates once a day through Sparkle. It reads the update
list from `raw.githubusercontent.com` and downloads updates from GitHub
Releases. GitHub sees your IP address and the app's name and version. Turn off
**Automatically check for updates** in Settings → App to stop the daily check.

Nothing else is contacted, apart from the links you click (for example this
page or a model licence), which open in your browser.

## What WhiskerFlow reads on your Mac

- **Microphone.** Only while you hold the dictation key (or between taps in
  tap mode), and during a meeting recording. Dictation audio is transcribed
  and kept as described above.
- **Mac audio (Screen Recording permission).** During a meeting recording,
  WhiskerFlow captures the sound your Mac plays, which includes the other
  participants. It does not keep or upload screen images. In Google Meet it
  briefly looks at the Meet window, in memory only, to see who is speaking.
- **Accessibility.**
  - To paste: it inserts the text where your cursor is.
  - To choose a writing style: it reads which app is in front and, for a
    browser, the page address or window title. These stay in memory; only the
    category is saved.
  - To learn corrections: it reads the text field around a paste (see
    Dictionary above).
  - For voice editing: it reads the text you have selected.
  - During a Google Meet recording in Chrome: it reads Meet's participant
    names and speaking indicators to label the transcript. Those names are part
    of the transcript sent to Atlas.
- **Clipboard.** To paste, WhiskerFlow saves your clipboard in memory, puts
  the text on it, pastes, then puts your original clipboard back.
- **Call detection.** With **Ask to record when a call starts** on (the
  default), WhiskerFlow watches which apps are using the microphone and, for a
  browser using it, the titles of its windows and tabs, to recognise a call.
  Nothing is recorded and nothing leaves your Mac until you choose to record.
- **Meeting schedule.** Your calendar is read from Atlas, not from your Mac.

## Meetings

**When recording starts.** A meeting is recorded only:
- when you start it yourself (**Record meeting** on the Meetings screen, or
  **Record** in the menu bar);
- when you answer **Record** to the "Record this meeting?" prompt, which says
  "Transcribed on this Mac, then the recording and transcript are uploaded to
  Atlas. Stops when the call ends."; or
- automatically, if you turned on **Record scheduled meetings automatically**
  (off unless you switch it on). Then a scheduled Google Meet call is recorded
  as soon as you join it in Chrome, without asking.

**Other people are recorded.** A recording includes everyone in the call, and
their voices and words are uploaded to Atlas with the transcript. WhiskerFlow
does not tell other participants that you are recording. Telling them, and
having their agreement where it is needed, is your responsibility.

## Signing out and uninstalling

**Signing out.** WhiskerFlow 2.1.0 has no sign-out button. Your device token
stays in your Keychain until you remove it (Keychain Access, item
`agency.thatworks.WhiskerFlow.meeting-capture`).

**Uninstalling.** Deleting the app does not delete its data. These stay until
you remove them:
- `~/Library/Application Support/WhiskerFlow` (history, audio, meetings,
  Dictionary, Insights, Assistant data and models);
- `~/Library/Application Support/FluidAudio/Models` (the Parakeet models);
- `~/Library/Logs/WhiskerFlow` (diagnostic logs);
- the preferences for `agency.thatworks.WhiskerFlow`;
- two Keychain items, `agency.thatworks.WhiskerFlow.meeting-capture` (your
  device token) and `agency.thatworks.WhiskerFlow.meeting-recording` (the
  meeting encryption key).

Anything already sent to Atlas (meetings, transcripts, notes, drafts and
leaderboard counts) stays in Atlas. Ask That Works about it.
