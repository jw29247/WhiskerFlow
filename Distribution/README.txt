WhiskerFlow for macOS
=====================

Hold your dictation key (fn by default), speak, release. WhiskerFlow transcribes
on-device and pastes the text at your cursor.

Install
-------
1. Drag WhiskerFlow.app into Applications.
2. Open WhiskerFlow from Applications.
3. If macOS says the developer cannot be verified, right-click WhiskerFlow.app
   and choose Open (this build is ad-hoc signed, not notarized).
4. Grant Microphone permission when prompted.
5. For auto-paste, grant Accessibility permission:
   System Settings > Privacy & Security > Accessibility > WhiskerFlow
   (The built-in onboarding screen links you straight there.)

Transcription
-------------
WhiskerFlow uses WhisperKit, which runs Whisper on the Apple Neural Engine.
No Python, no Homebrew, nothing else to install. The first time you dictate it
downloads a small model (~150 MB) and keeps it warm afterwards.

If you have no internet on first run, switch the engine to "Apple Speech
(built-in)" in Settings > Engine — it works fully offline with zero download.

Advanced (optional)
-------------------
Settings > Engine > "Whisper CLI" lets you point WhiskerFlow at your own
openai-whisper install. Run "Install Whisper.command" to set that up via
Homebrew. This is only needed if you specifically want the CLI engine.

Notes
-----
Keep WhiskerFlow in Applications so macOS permissions stick to one stable path.
