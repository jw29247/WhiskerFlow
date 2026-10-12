import Foundation
import WhiskerFlowAppSupport

/// Talks to macOS's Now Playing service. Since macOS 15.4 it answers only
/// Apple-signed processes, so the bundled helper library runs inside
/// `/usr/bin/perl`, one short process per call (about 0.1 s, off the main
/// thread). Without the helper, or if macOS stops answering, every call
/// reports nothing and dictation leaves media alone.
enum NowPlayingBridge {
    static let helperName = "libWhiskerFlowNowPlaying.dylib"

    static var helperURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent(helperName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func status() -> NowPlayingStatus? {
        run("wf_now_playing_status").flatMap(NowPlayingStatus.parse)
    }

    static func pause() { _ = run("wf_now_playing_pause") }
    static func play() { _ = run("wf_now_playing_play") }

    private static let script = """
        use DynaLoader;
        my $library = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1;
        my $symbol = DynaLoader::dl_find_symbol($library, $ARGV[1]) or exit 1;
        DynaLoader::dl_install_xsub("main::wf_call", $symbol);
        wf_call();
        """

    private static func run(_ symbol: String, timeout: TimeInterval = 2) -> String? {
        guard let helper = helperURL else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, helper.path, symbol]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
