#!/usr/bin/env python3
"""Update an extracted PrivMsg ios project while preserving its signing identity."""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import runpy
import shutil
import subprocess
import sys


SOURCE_PATHS = (
    "PrivMsg", "generate_project.py", "validate_project.py", "Install-PrivMsg.command",
    "tools", "tests", "vendor", "web-bundle.json", "README.md",
)
PROJECT = "PrivMsg.xcodeproj"
SIGNING = "Local/Signing.json"


def copy(source: Path, destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    else:
        shutil.copy2(source, destination, follow_symlinks=False)


def remove(path: Path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def check_project(root: Path):
    for name in ("generate_project.py", "PrivMsg/Info.plist", "PrivMsg/AppDelegate.swift",
                 "PrivMsg/LocalWebServer.swift", "PrivMsg/PrivMsgViewController.swift",
                 PROJECT + "/project.pbxproj"):
        if not (root / name).is_file() or (root / name).is_symlink():
            raise ValueError(f"Not a complete PrivMsg ios project: {root} (missing {name})")
    text = (root / PROJECT / "project.pbxproj").read_text()
    if "PrivMsg.app" not in text or "PBXNativeTarget" not in text:
        raise ValueError(f"The Xcode project is not the expected PrivMsg project: {root}")
    if not (root / "PrivMsg/Assets.xcassets").is_dir() or not any(
            (root / "PrivMsg" / name).is_dir() for name in ("Resources", "WebContent")):
        raise ValueError(f"The PrivMsg project is missing its icon or bundled web content: {root}")


def update(old: Path, new: Path):
    old, new = old.expanduser().resolve(), new.expanduser().resolve()
    if old == new or old in new.parents or new in old.parents:
        raise ValueError("The old and new ios folders must be separate, non-nested folders.")
    check_project(old)
    check_project(new)
    for name in SOURCE_PATHS:
        source = new / name
        if not source.exists() or source.is_symlink() or any(p.is_symlink() for p in source.rglob("*")):
            raise ValueError(f"The new download is incomplete or contains symbolic links: {name}")
        if (old / name).is_symlink():
            raise ValueError(f"The existing source path is a symbolic link: {name}")
    if (old / PROJECT).is_symlink() or (old / SIGNING).is_symlink():
        raise ValueError("The existing Xcode project or signing file is a symbolic link.")
    subprocess.run([sys.executable, str(new / "validate_project.py")], check=True)
    generator = runpy.run_path(str(new / "generate_project.py"))
    identity = generator["current_signing"](old)
    team = identity.get("team", "")
    bundle = identity.get("bundle", generator["DEFAULT_BUNDLE"])
    backup = old / "Local" / ("UpdateBackup-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True)
    paths = (*SOURCE_PATHS, PROJECT, SIGNING)
    existed = {name for name in paths if (old / name).exists()}
    for name in existed:
        copy(old / name, backup / name)
    print(f"Original files backed up to: {backup}", flush=True)
    try:
        for name in SOURCE_PATHS:
            remove(old / name)
            copy(new / name, old / name)
        # Keep the existing .xcodeproj directory, including Xcode user settings.
        # Explicit identity values prevent a stock release from changing the app.
        generator["generate"](team=team, bundle=bundle, root=old)
        subprocess.run([sys.executable, str(old / "validate_project.py")], check=True)
    except BaseException:
        for name in paths:
            remove(old / name)
            if name in existed:
                copy(backup / name, old / name)
        print(f"Update failed; original source, project and signing were restored from {backup}.", file=sys.stderr)
        raise
    print(f"Updated {old / PROJECT}")
    print(f"Preserved bundle identifier: {bundle}; team: {team or '(not selected yet)'}")
    print("In Xcode choose Product > Clean Build Folder, then Run. Keep the installed iPhone app.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old_ios_folder", type=Path)
    parser.add_argument("new_ios_folder", type=Path)
    args = parser.parse_args()
    try:
        update(args.old_ios_folder, args.new_ios_folder)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Could not update PrivMsg: {error}\n")


if __name__ == "__main__":
    main()
