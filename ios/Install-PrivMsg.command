#!/bin/bash
# Run with: bash /path/to/PrivMsg/ios/Install-PrivMsg.command
# macOS's built-in Bash 3.2 is supported. No Homebrew or third-party generator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRIVMSG_TEAM="${TEAM_ID:-}"
PRIVMSG_DEVICE="${DEVICE_ID:-}"
PRIVMSG_BUNDLE=""
PROJECT_ONLY=0
SIMULATOR_BUILD=0

die() { printf '\n%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
PrivMsg iPhone installer

  bash Install-PrivMsg.command [options]

  --team TEAMID          Select a 10-character Apple development Team ID.
  --device ID           Select a paired device UUID or UDID.
  --bundle-id ID        Override the default com.jordanrapp.PrivMsg.
  --project-only        Generate/validate and open the project without installing.
  --simulator-build     Check an unsigned iOS Simulator build.
  --help                Show this help.

On first use, choose your Personal Team in Xcode. Rerun this same script to
renew the installation. Keep the same team and bundle ID, and do not delete
the app first. The script does not ask for or store your Apple password.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) [ "$#" -ge 2 ] || die '--team requires a value'; PRIVMSG_TEAM="$2"; shift 2 ;;
    --device) [ "$#" -ge 2 ] || die '--device requires a value'; PRIVMSG_DEVICE="$2"; shift 2 ;;
    --bundle-id) [ "$#" -ge 2 ] || die '--bundle-id requires a value'; PRIVMSG_BUNDLE="$2"; shift 2 ;;
    --project-only) PROJECT_ONLY=1; shift ;;
    --simulator-build) SIMULATOR_BUILD=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help." ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die 'Build and installation require a Mac with full Xcode. The source package can be inspected on other systems.'
[ -f "$SCRIPT_DIR/generate_project.py" ] && [ -d "$SCRIPT_DIR/PrivMsg" ] || die 'Extract the complete package before running this script. Keep it beside generate_project.py and the PrivMsg folder.'
command -v python3 >/dev/null 2>&1 || die 'Python 3 is required. Install/finish setting up full Xcode and its command-line tools, then rerun.'
PYTHON="$(command -v python3)"

# Select full Xcode for this process only. Do not change the Mac's global tools.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  PRIVMSG_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
  if [ -x "$PRIVMSG_DEVELOPER/usr/bin/xcodebuild" ] && [ -d "$PRIVMSG_DEVELOPER/Platforms/iPhoneOS.platform" ]; then
    export DEVELOPER_DIR="$PRIVMSG_DEVELOPER"
  elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    die 'Install full Xcode, open it once, and finish its iOS components. Command Line Tools alone cannot build iPhone apps.'
  fi
fi
XCODEBUILD="$(xcrun --find xcodebuild 2>/dev/null || true)"
[ -x "$XCODEBUILD" ] || die 'The selected developer directory does not contain full Xcode. Choose Xcode in Xcode Settings > Locations > Command Line Tools.'
if ! "$XCODEBUILD" -version; then
  die 'Open Xcode once, accept its license, complete setup, then rerun this script.'
fi

LOCAL="$SCRIPT_DIR/Local"
PROJECT="$SCRIPT_DIR/PrivMsg.xcodeproj"
SETTINGS="$LOCAL/Signing.json"
mkdir -p "$LOCAL"
GENERATOR_ARGS=("$SCRIPT_DIR/generate_project.py")
[ -z "$PRIVMSG_TEAM" ] || GENERATOR_ARGS+=(--team "$PRIVMSG_TEAM")
[ -z "$PRIVMSG_BUNDLE" ] || GENERATOR_ARGS+=(--bundle-id "$PRIVMSG_BUNDLE")
"$PYTHON" "${GENERATOR_ARGS[@]}"
"$PYTHON" "$SCRIPT_DIR/validate_project.py"

saved_value() {
  "$PYTHON" - "$SETTINGS" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
PY
}
open_project() { open "$PROJECT"; }
PRIVMSG_TEAM="$(saved_value team)"
PRIVMSG_BUNDLE="$(saved_value bundle)"
DERIVED="$LOCAL/DerivedData"

if [ "$PROJECT_ONLY" -eq 1 ]; then
  open_project
  printf '\nProject ready: %s\n' "$PROJECT"
  exit 0
fi
if [ "$SIMULATOR_BUILD" -eq 1 ]; then
  "$XCODEBUILD" -project "$PROJECT" -scheme PrivMsg -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | tee "$LOCAL/simulator-build.log"
  printf '\nSimulator build passed. Native cross-app dragging still needs a physical iPhone test.\n'
  exit 0
fi

# Reuse an unambiguous, usable Apple Development certificate, as in Vision.
if [ -z "$PRIVMSG_TEAM" ]; then
  PRIVMSG_TEAM="$("$PYTHON" - <<'PY'
import re, subprocess
identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout.upper()
pem = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"], capture_output=True, text=True).stdout
teams = set()
for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S):
    result = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-fingerprint", "-sha1", "-nameopt", "RFC2253"], input=certificate, capture_output=True, text=True)
    team = re.search(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", result.stdout, re.M)
    fingerprint = re.search(r"Fingerprint=([A-Fa-f0-9:]+)", result.stdout)
    if team and fingerprint and fingerprint.group(1).replace(":", "").upper() in identities:
        teams.add(team.group(1))
print(next(iter(teams)) if len(teams) == 1 else "")
PY
)"
  if [ -n "$PRIVMSG_TEAM" ]; then
    "$PYTHON" "$SCRIPT_DIR/generate_project.py" --team "$PRIVMSG_TEAM"
  fi
fi

if [ -z "$PRIVMSG_TEAM" ]; then
  open_project
  cat <<'SIGNING'

One-time signing setup:
1. In Xcode Settings > Accounts, add your Apple account if necessary.
2. Select the blue PrivMsg project, then the PrivMsg target.
3. Open Signing & Capabilities, leave automatic signing enabled, and choose
   your Personal Team. Keep the bundle identifier unless Xcode reports a clash.
4. Save the project (Command-S), then return to this Terminal window.

SIGNING
  if [ -t 0 ]; then
    printf 'After choosing your Team in Xcode, press Return here: '
    IFS= read -r PRIVMSG_CONTINUE
    # Adopt the saved Xcode choices without rewriting the open project.
    "$PYTHON" - "$SCRIPT_DIR" <<'PY'
import importlib.util, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("privmsg_generator", root / "generate_project.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
values = module.current_signing(root)
temporary = root / "Local" / "Signing.json.tmp"
temporary.write_text(json.dumps(values, indent=2) + "\n")
os.replace(temporary, root / "Local" / "Signing.json")
PY
    "$PYTHON" "$SCRIPT_DIR/validate_project.py"
    PRIVMSG_TEAM="$(saved_value team)"
    PRIVMSG_BUNDLE="$(saved_value bundle)"
  fi
  if [ -z "$PRIVMSG_TEAM" ]; then
    printf '\nThe Xcode project is ready. Select your Team and iPhone in Xcode and press Run, or rerun this script with --team YOURTEAMID.\n'
    exit 0
  fi
fi

xcrun --find devicectl >/dev/null 2>&1 || die 'This Xcode does not include devicectl. Use Xcode 15 or later, compatible with the iOS version installed on your iPhone.'
DEVICE_JSON="$LOCAL/devices.json"
if ! xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null; then
  open_project
  die 'Xcode could not list paired devices. Connect/unlock your iPhone, accept Trust, and rerun or select it in Xcode.'
fi
"$PYTHON" - "$DEVICE_JSON" "$PRIVMSG_DEVICE" "$LOCAL/device-candidates.json" <<'PY'
import json, pathlib, sys
data = json.load(open(sys.argv[1]))
requested = sys.argv[2]
valid = []
for device in data.get("result", {}).get("devices", []):
    hw = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if hw.get("platform", props.get("platform")) not in ("iOS", "iPadOS"):
        continue
    if hw.get("reality", "physical") != "physical":
        continue
    ident = device.get("identifier", "")
    udid = hw.get("udid", "")
    if not ident or not udid:
        continue
    if requested:
        if requested not in (ident, udid):
            continue
    elif connection.get("tunnelState") != "connected" and connection.get("transportType") != "wired":
        continue
    valid.append({"identifier": ident, "udid": udid, "name": props.get("name", "iPhone"), "developerMode": props.get("developerModeStatus", "unknown")})
pathlib.Path(sys.argv[3]).write_text(json.dumps(valid))
for index, device in enumerate(valid, 1):
    name = str(device["name"]).replace("\n", " ").replace("\r", " ")
    print(f'{index}. {name} ({device["udid"]})')
PY
DEVICE_COUNT="$("$PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$LOCAL/device-candidates.json")"
if [ "$DEVICE_COUNT" -eq 0 ]; then
  open_project
  printf '\nConnect and unlock your iPhone, accept Trust, and enable Settings > Privacy & Security > Developer Mode. Then rerun.\n'
  printf 'The project is ready; you can also select your iPhone in Xcode and press Run.\n'
  exit 0
fi
DEVICE_NUMBER=1
if [ "$DEVICE_COUNT" -gt 1 ]; then
  if [ ! -t 0 ]; then
    die 'Several devices are available. Rerun with --device and the UUID or UDID of the intended iPhone.'
  fi
  printf 'Device number [1]: '
  IFS= read -r DEVICE_NUMBER
  DEVICE_NUMBER="${DEVICE_NUMBER:-1}"
fi
"$PYTHON" - "$LOCAL/device-candidates.json" "$DEVICE_NUMBER" "$LOCAL/device-selection.tsv" <<'PY'
import json, pathlib, sys
devices = json.load(open(sys.argv[1]))
try:
    number = int(sys.argv[2])
    if not 1 <= number <= len(devices):
        raise ValueError()
except ValueError:
    raise SystemExit("Invalid device number. Rerun and select one of the displayed numbers.")
device = devices[number - 1]
values = [device[key] for key in ("identifier", "udid", "name", "developerMode")]
pathlib.Path(sys.argv[3]).write_text("\t".join(str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ") for value in values) + "\n")
PY
IFS=$'\t' read -r PRIVMSG_DEVICE_ID PRIVMSG_DEVICE_UDID PRIVMSG_DEVICE_NAME DEVELOPER_MODE < "$LOCAL/device-selection.tsv"
if [ "$DEVELOPER_MODE" = disabled ]; then
  open_project
  printf '\nEnable Developer Mode on %s at Settings > Privacy & Security > Developer Mode, restart when asked, then rerun.\n' "$PRIVMSG_DEVICE_NAME"
  exit 0
fi

printf '\nBuilding PrivMsg for %s...\n' "$PRIVMSG_DEVICE_NAME"
if ! "$XCODEBUILD" -project "$PROJECT" -scheme PrivMsg -configuration Debug \
  -sdk iphoneos -destination "id=$PRIVMSG_DEVICE_UDID" -destination-timeout 60 \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build 2>&1 | tee "$LOCAL/device-build.log"; then
  open_project
  die "Build failed. See $LOCAL/device-build.log. Check signing in Xcode and that your Xcode version supports your iPhone's installed iOS."
fi
APP="$DERIVED/Build/Products/Debug-iphoneos/PrivMsg.app"
[ -d "$APP" ] || die "Xcode did not produce PrivMsg.app. See $LOCAL/device-build.log."
printf '\nInstalling on %s...\n' "$PRIVMSG_DEVICE_NAME"
xcrun devicectl device install app --device "$PRIVMSG_DEVICE_ID" "$APP"
if ! xcrun devicectl device process launch --device "$PRIVMSG_DEVICE_ID" "$PRIVMSG_BUNDLE"; then
  printf '\nPrivMsg is installed. Unlock your iPhone and open it. If asked, trust your developer in Settings > General > VPN & Device Management.\n'
fi
printf '\nPrivMsg installed. Sign in with your existing PrivMsg account.\n'
printf 'For renewal, run this same script: bash %q\n' "$SCRIPT_DIR/Install-PrivMsg.command"
printf 'Keep the same team and bundle identifier. Do not delete the installed app before renewing.\n'
