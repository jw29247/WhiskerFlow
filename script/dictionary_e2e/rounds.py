#!/usr/bin/env python3
"""Three dictations into a local chat box in Chrome (Enter sends and clears):

1. "Tell Grainne …" is heard as a real word; the user fixes it and sends at once.
   Expect: the written name is added to the Dictionary as a Word.
2. The same fix in a second message.  Expect: the misheard word becomes a variant.
3. A third dictation with no edit.  Expect: the name comes out right.
"""
import json, os, re, subprocess, sys, time

D = os.environ.get("WF_E2E_DIR", "/tmp/wf-dict-e2e")
DATA = f"{D}/home/Library/Application Support/WhiskerFlow"
CHROME = "com.google.Chrome"
FIX = os.environ.get("WF_E2E_FIX", "Grawnya")


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def osa(script):
    sh("osascript", "-e", script)


def value():
    return sh(f"{D}/axedit", CHROME, "value")


def dictionary():
    try:
        return json.load(open(f"{DATA}/Dictionary/dictionary.json")).get("entries", [])
    except (OSError, ValueError):
        return []


def focus_chat_box():
    for _ in range(10):
        osa(f'tell application "Google Chrome" to set URL of active tab of front window to "file://{D}/editor.html?focus=chat"')
        osa('tell application "Google Chrome" to activate')
        time.sleep(1.5)
        front = sh("osascript", "-e", 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
        if front == CHROME and "AXTextArea" in sh(f"{D}/axprobe", CHROME):
            return
    sys.exit("Could not focus the chat box in Chrome (is the screen unlocked?)")


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


def show(label):
    print(f"  {label}:", [(e["kind"], e["heard"] or None, e["written"], e.get("variants")) for e in dictionary()])


rounds = [("Tell Grainne the build is ready.", r"Tell\s+(.+?)\s+the build"),
          ("Ask Grainne to review it today.", r"Ask\s+(.+?)\s+to review")]
for number, (sentence, pattern) in enumerate(rounds, 1):
    focus_chat_box()
    pasted = dictate(sentence)
    match = re.search(pattern, pasted)
    heard = match.group(1) if match else None
    print(f"round {number}: pasted {pasted!r}, heard {heard!r}")
    if heard and heard != FIX:
        time.sleep(0.8)
        sh(f"{D}/axedit", CHROME, "fix", heard, FIX)
    osa('tell application "System Events" to key code 36')  # send inside the debounce
    time.sleep(3)
    show("dictionary")

focus_chat_box()
pasted = dictate("I think Grainne will join us later.")
osa('tell application "System Events" to key code 36')
print(f"round 3: pasted {pasted!r} with no edit")
print("PASS" if FIX in pasted else "FAIL: the learned name was not applied")
