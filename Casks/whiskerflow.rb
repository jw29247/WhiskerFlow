cask "whiskerflow" do
  version "0.5.1"
  sha256 "0e2210ffc1d8182b45745e55b6dbd792e1fec0bcadaff87006b1bbb66f9963ce"

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
