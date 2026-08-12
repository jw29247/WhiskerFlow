cask "whiskerflow" do
  version "0.8.0"
  sha256 "196bfc369d2775bb23f160e8abd12c2e3bccb50c5fa2242264d9d5a7dd783ac3"

  url "https://github.com/jw29247/WhiskerFlow/releases/download/v#{version}/WhiskerFlow-#{version}.dmg"
  name "WhiskerFlow"
  desc "On-device push-to-talk dictation for macOS"
  homepage "https://github.com/jw29247/WhiskerFlow"

  depends_on macos: :sonoma

  app "WhiskerFlow.app"

  caveats <<~EOS
    WhiskerFlow needs Microphone and Accessibility permissions to record and
    paste at your cursor. Grant them in System Settings > Privacy & Security.

    The first transcription downloads a Whisper model (~150 MB). To stay fully
    offline, switch the engine to "Apple Speech (built-in)" in Settings.
  EOS
end
