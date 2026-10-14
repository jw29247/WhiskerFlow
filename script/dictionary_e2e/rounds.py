#!/usr/bin/env python3
"""Correct one real dictation, restart the candidate, then dictate without editing.

Uses a dedicated Chrome window and isolated app data. Enter sends only to the
local test page. A missing replacement or failed restart exits unsuccessfully.
"""
import json, os, re, subprocess, time

D = os.environ.get("WF_E2E_DIR", "/tmp/wf-dict-e2e")
DATA = f"{D}/home/Library/Application Support/WhiskerFlow"
CHROME = "com.google.Chrome"
FIX = os.environ.get("WF_E2E_FIX", "Grawnya")
SUITE = os.environ.get("WF_E2E_SUITE", "agency.thatworks.WhiskerFlow.e2e.dictionary")
APP = os.path.realpath(f"{D}/WhiskerFlow-E2E.app")
window_id = None


def sh(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def osa(script):
    return sh("osascript", "-e", script)


def value():
    return sh(f"{D}/axedit", CHROME, "value")


def dictionary():
    try:
        return json.load(open(f"{DATA}/Dictionary/dictionary.json")).get("entries", [])
    except (OSError, ValueError):
        return []


def focus_chat_box():
    for _ in range(10):
        osa(f'tell application "Google Chrome" to set index of window id {window_id} to 1')
        osa(f'tell application "Google Chrome" to set URL of active tab of window id {window_id} to "file://{D}/editor.html?focus=chat"')
        osa('tell application "Google Chrome" to activate')
        time.sleep(1.5)
        front = sh("osascript", "-e", 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
        if front == CHROME and "AXTextArea" in sh(f"{D}/axprobe", CHROME):
            return
    raise RuntimeError("Could not focus the local chat box in Chrome")


def dictate(sentence):
    before = value()
    sh(f"{D}/wfnotify", "press")
    time.sleep(0.9)
    sh("say", "-v", "Samantha", "-r", "170", sentence)
    time.sleep(0.6)
    sh(f"{D}/wfnotify", "release")
    for _ in range(60):
        time.sleep(0.5)
        now = value()
        if now != before and now.strip():
            return now
    return value()


def candidate_pids():
    return [int(line.strip().split(None, 1)[0]) for line in sh("ps", "-axo", "pid=,command=").splitlines()
            if line.strip().split(None, 1)[-1].startswith(f"{APP}/Contents/MacOS/WhiskerFlow")]


def quit_candidate():
    for pid in candidate_pids():
        sh("osascript", "-l", "JavaScript", "-e",
           f"ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}).terminate;")
    for _ in range(40):
        if not candidate_pids():
            return
        time.sleep(0.25)
    raise RuntimeError("Candidate did not quit gracefully")


front = osa('tell application "System Events" to get bundle identifier of first process whose frontmost is true')
try:
    if osa('tell application "Google Chrome" to count windows') == "0":
        raise RuntimeError("Open a Chrome profile or Guest window before running the microphone check")
    window_id = osa('tell application "Google Chrome" to get id of (make new window)')
    focus_chat_box()
    sentence = "Tell Grainne the build is ready."
    pasted = dictate(sentence)
    match = re.search(r"Tell\s+(.+?)\s+the build", pasted, re.IGNORECASE)
    heard = match.group(1) if match else None
    print(f"round 1: pasted {pasted!r}, heard {heard!r}", flush=True)
    if not heard or heard == FIX:
        raise RuntimeError("The first dictation did not provide a mishearing to correct")
    time.sleep(0.8)
    sh(f"{D}/axedit", CHROME, "fix", heard, FIX)
    osa('tell application "System Events" to key code 36')
    learned = []
    for _ in range(20):
        learned = [e for e in dictionary() if e["written"] == FIX and
                   heard.lower() in [s.lower() for s in [e["heard"]] + e.get("variants", [])]]
        if learned:
            break
        time.sleep(0.25)
    if not learned:
        raise RuntimeError("The first correction saved no heard-to-written replacement")
    print("First correction saved a replacement:", learned, flush=True)

    quit_candidate()
    sh("open", "-n", "--env", f"CFFIXED_USER_HOME={D}/home", "--env", "WHISKERFLOW_SKIP_ATLAS_SIGN_IN=1", APP,
       "--args", "--debug-dictation-trigger", f"--e2e-defaults-suite={SUITE}")
    time.sleep(10)
    if not candidate_pids():
        raise RuntimeError("Candidate failed to restart")
    focus_chat_box()
    pasted = dictate(sentence)
    print(f"round 2 after restart: pasted {pasted!r} with no edit", flush=True)
    if FIX not in pasted:
        raise RuntimeError("The learned name was not applied after restart")
    osa('tell application "System Events" to key code 36')
    print("PASS: one correction, persisted replacement, restart, automatic dictation delivery", flush=True)
finally:
    quit_candidate()
    if window_id:
        osa(f'tell application "Google Chrome" to if exists window id {window_id} then close window id {window_id}')
    if front:
        osa(f'tell application id "{front}" to activate')
