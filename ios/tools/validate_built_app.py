#!/usr/bin/env python3
"""Validate the built Simulator app before ad hoc signing or launch."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import sys


def validate(app: Path, bundle_id: str = "com.jordanrapp.PrivMsg") -> None:
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError(f"App bundle not found: {app}")
    # These names change Apple's interpretation of the bundle layout. In
    # particular, Resources/ is not a valid custom folder in an iOS app.
    for name in ("Resources", "Contents", "Versions"):
        if (app / name).exists() or (app / name).is_symlink():
            raise ValueError(f"Reserved folder at iOS app root: {name}")
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if not isinstance(info, dict):
        raise ValueError("The built Info.plist is not a dictionary")
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
                "CFBundleVersion", "CFBundleShortVersionString"):
        value = info.get(key)
        if not isinstance(value, str) or not value or "$(" in value or "${" in value:
            raise ValueError(f"Missing or unresolved built Info.plist key: {key}")
    if info["CFBundleIdentifier"] != bundle_id:
        raise ValueError(f"Unexpected bundle identifier: {info['CFBundleIdentifier']}")
    if info["CFBundlePackageType"] != "APPL":
        raise ValueError("The built bundle is not an APPL application")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise ValueError("Only an iPhone Simulator build may be ad hoc signed by this check")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("The main executable must be at the app bundle root")
    if not (app / executable).is_file() or (app / executable).stat().st_size == 0:
        raise ValueError(f"Missing or empty app executable: {executable}")
    for name in ("index.html", "enhancements.js", "clipboard.js", "native-bridge.js"):
        if not (app / "WebContent" / name).is_file():
            raise ValueError(f"Missing bundled web content: WebContent/{name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--bundle-id", default="com.jordanrapp.PrivMsg")
    args = parser.parse_args()
    try:
        validate(args.app, args.bundle_id)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Built app validation failed: {error}", file=sys.stderr)
        return 1
    print("Built Simulator bundle structure, Info.plist, executable and web content are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
