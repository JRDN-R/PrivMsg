#!/bin/bash
# Update an existing PrivMsg Xcode download, preserving its signing identity.
set -euo pipefail
PRIVMSG_SOURCE_COMMIT="d0bf04c29b7da40e5dded55972380617c347351d"
die() { printf '%s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die 'Run this updater on your Mac.'
[ "$#" -eq 1 ] || die 'Usage: bash Update-PrivMsg.command /path/to/PrivMsg/ios'
[ -f "$1/PrivMsg.xcodeproj/project.pbxproj" ] || die 'Pass the ios folder containing your existing PrivMsg.xcodeproj.'
PRIVMSG_OLD_IOS="$(cd "$1" && pwd)"
command -v python3 >/dev/null 2>&1 || die 'Finish setting up full Xcode and Python 3, then rerun.'
PRIVMSG_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/privmsg-update.XXXXXX")"
trap 'rm -rf "$PRIVMSG_TEMP"' EXIT
printf '\nDownloading the complete PrivMsg update...\n'
/usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
  "https://github.com/JRDN-R/PrivMsg/archive/$PRIVMSG_SOURCE_COMMIT.zip" \
  --output "$PRIVMSG_TEMP/PrivMsg.zip"
/usr/bin/ditto -x -k "$PRIVMSG_TEMP/PrivMsg.zip" "$PRIVMSG_TEMP/source"
PRIVMSG_NEW_IOS="$PRIVMSG_TEMP/source/PrivMsg-$PRIVMSG_SOURCE_COMMIT/ios"
python3 "$PRIVMSG_NEW_IOS/tools/update_existing_project.py" "$PRIVMSG_OLD_IOS" "$PRIVMSG_NEW_IOS"
# The installer builds in its own Local/DerivedData directory. Clear only that
# generated build output so an older bundle cannot retain the Resources folder.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  PRIVMSG_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
  if [ -d "$PRIVMSG_DEVELOPER/Platforms/iPhoneOS.platform" ]; then
    export DEVELOPER_DIR="$PRIVMSG_DEVELOPER"
  elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    die 'Source updated. Open full Xcode, clean the PrivMsg build, and Run.'
  fi
fi
if [ -d "$PRIVMSG_OLD_IOS/Local/DerivedData/Build" ]; then
  xcrun xcodebuild -project "$PRIVMSG_OLD_IOS/PrivMsg.xcodeproj" -scheme PrivMsg \
    -configuration Debug -sdk iphoneos \
    -derivedDataPath "$PRIVMSG_OLD_IOS/Local/DerivedData" clean
fi
/bin/bash "$PRIVMSG_OLD_IOS/Install-PrivMsg.command"
