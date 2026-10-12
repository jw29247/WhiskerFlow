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
WhiskerFlow uses Parakeet TDT v3, which runs on the Apple Neural Engine.
No Python, no Homebrew, nothing else to install. The first time you dictate it
downloads its model (about 500 MB) and keeps it warm afterwards. Meetings are
transcribed with the same model.

If you have no internet on first run, WhiskerFlow uses Apple Speech (built-in)
until the download finishes; it works fully offline with zero download.

Notes
-----
Keep WhiskerFlow in Applications so macOS permissions stick to one stable path.
