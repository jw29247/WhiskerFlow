cask "whiskerflow" do
  version "0.8.7"
  sha256 "01fd16fefdacde716c95fa3914fddcf44c52801dd62974cd537fafcfee3a457d"

  url "https://github.com/jw29247/WhiskerFlow/releases/download/v#{version}/WhiskerFlow-#{version}.dmg"
  name "WhiskerFlow"
  desc "On-device push-to-talk dictation for macOS"
  homepage "https://github.com/jw29247/WhiskerFlow"

  depends_on macos: :sonoma

  app "WhiskerFlow.app"

  caveats <<~EOS
    WhiskerFlow needs Microphone and Accessibility permissions to record and
    paste at your cursor. Grant them in System Settings > Privacy & Security.

    The first transcription may prepare or download the on-device speech model.
    To stay fully offline, switch the engine to "Apple Speech (built-in)" in
    Settings.
  EOS
end
