#!/usr/bin/env python3
"""Register the signed helper after the user approves Chrome extension access."""
import argparse, base64, hashlib, json, pathlib, subprocess
parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=pathlib.Path)
parser.add_argument('--install', action='store_true', help='Write the Chrome native-host registration')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'browser-extension/manifest.json').read_text())
raw = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
extension_id = ''.join(chr(ord('a') + int(c, 16)) for c in raw)
helper = args.bundle.resolve() / 'Contents/MacOS/WhiskerFlowMeetBridge'
subprocess.run(['codesign', '--verify', '--strict', str(args.bundle.resolve())], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
registration = dict(name='agency.thatworks.whiskerflow.meet', description='WhiskerFlow local Meet speaker metadata', path=str(helper), type='stdio', allowed_origins=[f'chrome-extension://{extension_id}/'])
if args.install:
    folder = pathlib.Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'agency.thatworks.whiskerflow.meet.json'
    path.write_text(json.dumps(registration, indent=2) + '\n')
    path.chmod(0o600)
    print(f'Registered native host for extension {extension_id}.')
else:
    print(f'Ready to register extension {extension_id}; no registration changed.')
print(f'Load unpacked extension from {root / "browser-extension"}')
