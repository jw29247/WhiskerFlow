import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndExitCode() async throws {
        let output = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            environment: [:],
            timeout: 5
        )

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testTimeoutEscalatesToKillAndThrowsPromptly() async throws {
        let marker = "whiskerflow-runner-\(UUID().uuidString)"
        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap \"\" TERM; sleep 30 # \(marker)"],
                environment: [:],
                timeout: 1
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .timedOut(seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)

        // SIGTERM is ignored by the child, so only the SIGKILL escalation can reap it.
        var alive = true
        for _ in 0..<40 where alive {
            try await Task.sleep(nanoseconds: 200_000_000)
            alive = Self.processExists(matching: marker)
        }
        XCTAssertFalse(alive)
    }

    private static func processExists(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func testGrandchildHoldingPipeDoesNotBlockOnEOF() async {
        let started = Date()
        do {
            let output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30 & echo out"],
                environment: [:],
                timeout: 1
            )
            XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .timedOut(seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
