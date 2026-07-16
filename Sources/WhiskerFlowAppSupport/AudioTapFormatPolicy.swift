import AVFoundation

public enum AudioTapFormatPolicy {
    /// After changing an AVAudioEngine input device, the node's output format can
    /// still describe the previous system-default microphone. The input scope is
    /// the assigned device's hardware format and is the safe format for its tap.
    public static func captureFormat(
        hardwareInput: AVAudioFormat,
        nodeOutput _: AVAudioFormat
    ) -> AVAudioFormat {
        hardwareInput
    }
}
