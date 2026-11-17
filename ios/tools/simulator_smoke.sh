#!/bin/bash
# Unsigned simulator launch check. Does not sign in or upload/delete user data.
# Usage: bash simulator_smoke.sh /path/to/PrivMsg.app /path/to/screenshot.png
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 2 ] || die 'Usage: simulator_smoke.sh APP_PATH SCREENSHOT_PATH'
APP_PATH="$1"
SCREENSHOT_PATH="$2"
BUNDLE_ID=com.jordanrapp.PrivMsg
[ -d "$APP_PATH" ] && [ -f "$APP_PATH/Info.plist" ] || die "App bundle not found: $APP_PATH"
command -v xcrun >/dev/null 2>&1 || die 'This check requires Xcode command-line tools on macOS.'
command -v python3 >/dev/null 2>&1 || die 'Python 3 is required for simulator JSON parsing.'
python3 - "$APP_PATH/Info.plist" "$BUNDLE_ID" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
if info.get('CFBundleIdentifier') != sys.argv[2]:
    raise SystemExit('The app bundle identifier is not com.jordanrapp.PrivMsg.')
if 'iPhoneSimulator' not in info.get('CFBundleSupportedPlatforms', []):
    raise SystemExit('Pass the iOS Simulator build, not the signed iPhone build.')
PY

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/privmsg-smoke.XXXXXX")"
BOOTED_BY_SCRIPT=0
SIMULATOR_ID=""
cleanup() {
  if [ "$BOOTED_BY_SCRIPT" -eq 1 ] && [ -n "$SIMULATOR_ID" ]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun simctl list devices available --json > "$WORK_DIR/devices.json"
python3 - "$WORK_DIR/devices.json" "$WORK_DIR/selected.tsv" <<'PY'
import json, pathlib, re, sys
data = json.load(open(sys.argv[1]))
candidates = []
for runtime, devices in data.get('devices', {}).items():
    match = re.search(r'\.iOS-(\d+(?:-\d+)*)$', runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split('-'))
    if version < (17,):
        continue
    for device in devices:
        if not device.get('isAvailable', False) or not device.get('name', '').startswith('iPhone'):
            continue
        if device.get('state') not in ('Booted', 'Shutdown'):
            continue
        candidates.append((version, device))
if not candidates:
    raise SystemExit('No available iPhone simulator on iOS 17 or later. Install an iOS Simulator runtime in Xcode.')
# Prefer the newest installed runtime and an already booted device within it.
candidates.sort(key=lambda entry: (entry[0], entry[1]['state'] == 'Booted', entry[1]['name']), reverse=True)
device = candidates[0][1]
values = [device['udid'], device['state'], device['name']]
pathlib.Path(sys.argv[2]).write_text('\t'.join(str(value).replace('\t', ' ').replace('\n', ' ') for value in values) + '\n')
PY
IFS=$'\t' read -r SIMULATOR_ID SIMULATOR_STATE SIMULATOR_NAME < "$WORK_DIR/selected.tsv"
printf 'Simulator smoke check: %s (%s)\n' "$SIMULATOR_NAME" "$SIMULATOR_ID"
if [ "$SIMULATOR_STATE" != Booted ]; then
  xcrun simctl boot "$SIMULATOR_ID"
  BOOTED_BY_SCRIPT=1
fi
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
if ! xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID"; then
  die 'PrivMsg failed to launch in the simulator.'
fi
# Give WKWebView and the bundled sign-in interface a brief first-launch window.
sleep 25
mkdir -p "$(dirname "$SCREENSHOT_PATH")"
xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "$SCREENSHOT_PATH"
python3 - "$SCREENSHOT_PATH" <<'PY'
from pathlib import Path
import struct, sys
data = Path(sys.argv[1]).read_bytes()
if len(data) < 24 or data[:8] != b'\x89PNG\r\n\x1a\n':
    raise SystemExit('Simulator did not produce a valid PNG screenshot.')
width, height = struct.unpack('>II', data[16:24])
if width < 100 or height < 100:
    raise SystemExit('Simulator screenshot has invalid dimensions.')
print(f'Launch command succeeded; screenshot saved ({width} x {height}): {sys.argv[1]}')
print('Inspect the image to confirm the PrivMsg sign-in screen. No sign-in or file transfer was performed.')
PY
