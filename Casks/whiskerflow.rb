cask "whiskerflow" do
  version "2.1.1"
  sha256 "905f646adaed922e621e501a82c02d3e6df6f029d0d5f57aa42908a3d0b8a447"

  url "https://github.com/jw29247/WhiskerFlow/releases/download/v#{version}/WhiskerFlow-#{version}.dmg"
  name "WhiskerFlow"
  desc "On-device push-to-talk dictation for macOS"
  homepage "https://github.com/jw29247/WhiskerFlow"

  depends_on macos: :tahoe
  # FluidAudio (the default Parakeet engine) does not build for x86_64 yet.
  depends_on arch: :arm64

  app "WhiskerFlow.app"

  caveats <<~EOS
    WhiskerFlow needs Microphone and Accessibility permissions to record and
    paste at your cursor. Grant them in System Settings > Privacy & Security.

    The first transcription may prepare or download the on-device speech model.
    To stay fully offline, switch the engine to "Apple Speech (built-in)" in
    Settings.
  EOS
end
