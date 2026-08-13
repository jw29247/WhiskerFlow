cask "whiskerflow" do
  version "0.8.3"
  sha256 "eca46ade79d6acc1e6501d1a2e4c1264493956c075ef1bd639541cc0fb03db90"

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
