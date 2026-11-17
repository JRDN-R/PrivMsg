#!/bin/bash
# Verify packaging with Apple's signing machinery without an Apple account.
# This signs only an unsigned CI Simulator build, never an iPhone build.
set -euo pipefail
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: verify_simulator_bundle.sh APP_PATH' >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'This check requires macOS codesign.' >&2; exit 1; }
PRIVMSG_TOOLS="$(cd "$(dirname "$0")" && pwd)"
python3 "$PRIVMSG_TOOLS/validate_built_app.py" "$1"
/usr/bin/codesign --force --sign - --timestamp=none "$1"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$1"
printf '%s\n' 'Simulator app passed ad hoc signing and strict signature verification.'
