WhiskerFlow for macOS
=====================

That Works' internal dictation tool. Hold your dictation key (fn by default),
speak, release. WhiskerFlow transcribes on your Mac and pastes the text at your
cursor. You need a That Works Atlas account: sign in before it will dictate.

Privacy: https://github.com/jw29247/WhiskerFlow/blob/main/PRIVACY.md

Install
-------
1. Drag WhiskerFlow.app into Applications.
2. Open WhiskerFlow from Applications.
3. Sign in with Atlas. (The app is Developer ID signed and notarised by Apple,
   so it opens normally.)
4. Grant Microphone permission when prompted.
5. For auto-paste, grant Accessibility permission:
   System Settings > Privacy & Security > Accessibility > WhiskerFlow
   (The built-in onboarding screen links you straight there.)

Transcription
-------------
WhiskerFlow uses Parakeet TDT v3, which runs on the Apple Neural Engine.
No Python, no Homebrew, nothing else to install. The first time you dictate it
downloads its model from Hugging Face and keeps it warm afterwards. Meetings are
transcribed with the same model.

If the model isn't downloaded yet, WhiskerFlow uses Apple Speech (built-in)
until the download finishes; it works fully offline with zero download, for the
languages macOS can recognise on this Mac. It never sends audio to Apple.

Notes
-----
Keep WhiskerFlow in Applications so macOS permissions stick to one stable path.
