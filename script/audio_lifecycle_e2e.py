#!/usr/bin/env python3
"""Stress real microphone start/stop in a signed DEBUG bundle on an unlocked Mac.

Uses isolated preferences and data, shared model files, and the existing debug
dictation trigger. Short, silent captures exercise teardown without dictating
into another app. Requires the production bundle ID and microphone permission.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--input-uid", default="system-default")
    parser.add_argument("--rounds", type=int, default=40)
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    home = output / "home"
    support = home / "Library/Application Support"
    (support / "WhiskerFlow").mkdir(parents=True)
    (home / "Documents").mkdir()
    real_support = Path.home() / "Library/Application Support"
    for relative in ["WhiskerFlow/Models", "FluidAudio"]:
        source = real_support / relative
        if source.exists():
            (support / relative).symlink_to(source, target_is_directory=True)

    suite = f"agency.thatworks.WhiskerFlow.e2e.audio-{time.time_ns()}"
    settings = {
        "engine": "parakeetTDTv3", "language": "en", "recordingMode": "holdToTalk",
        "selectedInputUID": args.input_uid,
        "languageAutoMigrated": True, "parakeetTDTv3DefaultMigrated": True,
        "ignoreSpeakerAudio": False, "liveTranscription": False,
        "meetingModeEnabled": False, "playSounds": False,
        "pauseMediaWhileDictating": False, "showMenuBarExtra": False,
    }
    for key, value in settings.items():
        kind = "-bool" if isinstance(value, bool) else "-string"
        run("defaults", "write", suite, key, kind, str(value).lower() if isinstance(value, bool) else value)
    progress = {"finishedAt": time.time() - 978307200, "current": "done",
                "furthest": "done", "completed": [], "skipped": []}
    run("defaults", "write", suite, "onboardingProgress", "-data", json.dumps(progress).encode().hex())
    notify = output / "wfnotify"
    source = Path(__file__).resolve().parent / "dictionary_e2e/wfnotify.swift"
    run("swiftc", "-O", str(source), "-o", str(notify))
    log = home / "Library/Logs/WhiskerFlow/diagnostics.jsonl"

    def rows():
        if not log.exists():
            return []
        result = []
        for line in log.read_text().splitlines():
            try:
                result.append(json.loads(line))
            except ValueError:
                pass  # The writer may be midway through the last row.
        return result

    def wait_for(predicate, description):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            current = rows()
            match = next((row for row in current if predicate(row)), None)
            if match:
                return match
            time.sleep(0.025)
        raise RuntimeError(f"Timed out waiting for {description}; inspect {log}")

    run("open", "-n", "--env", f"CFFIXED_USER_HOME={home}", "--env",
        "WHISKERFLOW_SKIP_ATLAS_SIGN_IN=1", str(app), "--args",
        "--debug-dictation-trigger", f"--e2e-defaults-suite={suite}")
    launched = wait_for(lambda row: row.get("event") == "app_started", "app launch")
    pid = int(launched["pid"])
    rounds = []
    try:
        time.sleep(2)
        for index in range(args.rounds):
            before = time.time()
            run(str(notify), "press")
            recording = wait_for(lambda row: float(row["timestamp"]) >= before
                                 and row.get("state") == "recording", "recording start")
            session = recording["session"]
            time.sleep([0, 0.01, 0.02, 0.03, 0.05][index % 5])
            run(str(notify), "release")
            finished = wait_for(lambda row: row.get("session") == session
                                and row.get("event") == "finish_returned", "recording finish")
            rounds.append({"round": index + 1, "session": session,
                           "finish_ms": float(finished["elapsed_ms"])})
            print(f"{index + 1}/{args.rounds}: start and finish returned", flush=True)
        # Finish returns before async teardown. The next start shares its engine
        # queue, so reaching recording proves the final counted teardown returned.
        before = time.time()
        run(str(notify), "press")
        probe = wait_for(lambda row: float(row["timestamp"]) >= before
                         and row.get("state") == "recording", "final teardown barrier")
        run(str(notify), "release")
        wait_for(lambda row: row.get("session") == probe["session"]
                 and row.get("event") == "finish_returned", "probe finish")
        stalls = [row for row in rows() if row.get("event") in
                  {"main_thread_stalled", "finish_timeout", "capture_engine_timeout"}]
        if stalls:
            raise RuntimeError(f"Capture logged {len(stalls)} stalls or timeouts")
        summary = {"rounds": rounds, "stalls": 0, "input_uid": args.input_uid,
                   "build": launched["build"]}
        (output / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"PASS: {args.rounds} real microphone start/stop cycles, zero stalls/timeouts", flush=True)
    finally:
        run("osascript", "-l", "JavaScript", "-e",
            f"ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}).terminate;")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("Candidate did not quit after the capture lifecycle test")
        run("defaults", "delete", suite)


if __name__ == "__main__":
    main()
