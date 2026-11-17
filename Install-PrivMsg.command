#!/bin/bash
# Standalone Mac installer. This downloads a pinned source revision, then uses
# Apple's Xcode tools to build, sign, install and launch the app on your iPhone.
set -euo pipefail

PRIVMSG_SOURCE_COMMIT="d0bf04c29b7da40e5dded55972380617c347351d"
PRIVMSG_INSTALL_ROOT="${PRIVMSG_INSTALL_ROOT:-$HOME/Developer/PrivMsg-iOS}"
PRIVMSG_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Run this installer on your Mac with full Xcode installed.' >&2
  exit 1
fi

# A downloaded repository ZIP already contains everything needed.
if [ -f "$PRIVMSG_SCRIPT_DIR/ios/Install-PrivMsg.command" ] && [ -f "$PRIVMSG_SCRIPT_DIR/ios/web-bundle.json" ]; then
  exec /bin/bash "$PRIVMSG_SCRIPT_DIR/ios/Install-PrivMsg.command" "$@"
fi

PRIVMSG_RELEASE="$PRIVMSG_INSTALL_ROOT/Releases/$PRIVMSG_SOURCE_COMMIT"
mkdir -p "$PRIVMSG_INSTALL_ROOT/Releases" "$PRIVMSG_INSTALL_ROOT/Local"
if [ ! -d "$PRIVMSG_RELEASE" ]; then
  PRIVMSG_TEMP="$(mktemp -d "$PRIVMSG_INSTALL_ROOT/.download.XXXXXX")"
  trap 'rm -rf "$PRIVMSG_TEMP"' EXIT
  printf '\nDownloading PrivMsg source…\n'
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
    "https://github.com/JRDN-R/PrivMsg/archive/$PRIVMSG_SOURCE_COMMIT.zip" \
    --output "$PRIVMSG_TEMP/PrivMsg.zip"
  /usr/bin/ditto -x -k "$PRIVMSG_TEMP/PrivMsg.zip" "$PRIVMSG_TEMP/unpacked"
  PRIVMSG_UNPACKED="$PRIVMSG_TEMP/unpacked/PrivMsg-$PRIVMSG_SOURCE_COMMIT"
  if [ ! -f "$PRIVMSG_UNPACKED/ios/Install-PrivMsg.command" ] || [ ! -f "$PRIVMSG_UNPACKED/ios/PrivMsg/Info.plist" ]; then
    printf '%s\n' 'The downloaded package is incomplete. Rerun the installer.' >&2
    exit 1
  fi
  mv "$PRIVMSG_UNPACKED" "$PRIVMSG_RELEASE"
  rm -rf "$PRIVMSG_TEMP"
  trap - EXIT
fi

if [ ! -f "$PRIVMSG_RELEASE/ios/Install-PrivMsg.command" ]; then
  printf 'The folder %s already exists without a complete app. Rename it and rerun; nothing was overwritten.\n' "$PRIVMSG_RELEASE" >&2
  exit 1
fi

# Share signing choices and build caches across future pinned releases. Never
# replace a user-owned local directory or change the installed app identifier.
if [ ! -e "$PRIVMSG_RELEASE/ios/Local" ] && [ ! -L "$PRIVMSG_RELEASE/ios/Local" ]; then
  ln -s "$PRIVMSG_INSTALL_ROOT/Local" "$PRIVMSG_RELEASE/ios/Local"
fi
printf '\nPrivMsg project: %s\n' "$PRIVMSG_RELEASE/ios/PrivMsg.xcodeproj"
exec /bin/bash "$PRIVMSG_RELEASE/ios/Install-PrivMsg.command" "$@"
