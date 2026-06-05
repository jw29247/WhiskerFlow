cask "whiskerflow" do
  version "0.2.0"
  sha256 :no_check # ad-hoc signed build; pin a real checksum once notarized

  url "https://github.com/jw29247/WhiskerFlow/releases/download/v#{version}/WhiskerFlow-#{version}.dmg"
  name "WhiskerFlow"
  desc "On-device push-to-talk dictation for macOS"
  homepage "https://github.com/jw29247/WhiskerFlow"

  depends_on macos: ">= :sonoma"

  app "WhiskerFlow.app"

  caveats <<~EOS
    WhiskerFlow needs Microphone and Accessibility permissions to record and
    paste at your cursor. Grant them in System Settings > Privacy & Security.

    The first transcription downloads a Whisper model (~150 MB). To stay fully
    offline, switch the engine to "Apple Speech (built-in)" in Settings.
  EOS
end
