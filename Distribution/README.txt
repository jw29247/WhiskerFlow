WhiskerFlow for macOS
=====================

Install
-------
1. Drag WhiskerFlow.app into Applications.
2. Open WhiskerFlow from Applications.
3. If macOS says the developer cannot be verified, right-click WhiskerFlow.app and choose Open.
4. Grant Microphone permission when prompted.
5. For auto-paste, grant Accessibility permission:
   System Settings > Privacy & Security > Accessibility > WhiskerFlow

Whisper dependency
------------------
WhiskerFlow uses the local Whisper CLI. It is not bundled inside the app.

If transcription fails with a missing Whisper command, run Install Whisper.command.
That script uses Homebrew to install openai-whisper:

    brew install openai-whisper

The first transcription with the base model may download the model. Later runs are faster.

Notes
-----
WhiskerFlow should live in Applications so macOS permissions stick to one stable app path.
This build is ad-hoc signed for friends/testing, not notarized with an Apple Developer ID.
