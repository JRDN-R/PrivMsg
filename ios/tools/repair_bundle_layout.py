#!/usr/bin/env python3
"""Repair the original PrivMsg iOS package without replacing signing choices."""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import shutil
import subprocess
import sys


REPLACEMENTS = {
    "generate_project.py": [('"Resources"', '"WebContent"')],
    "validate_project.py": [('"Resources"', '"WebContent"')],
    "PrivMsg/PrivMsgViewController.swift": [('forResource: "Resources"', 'forResource: "WebContent"')],
    "tools/build_web_bundle.mjs": [("PrivMsg/Resources", "PrivMsg/WebContent")],
    "tests/native-bridge.test.mjs": [("PrivMsg/Resources/", "PrivMsg/WebContent/")],
}


def repair(root: Path):
    root = root.expanduser().resolve()
    project = root / "PrivMsg.xcodeproj/project.pbxproj"
    old = root / "PrivMsg/Resources"
    new = root / "PrivMsg/WebContent"
    required = [project, root / "PrivMsg/Info.plist"] + [root / name for name in REPLACEMENTS]
    if not all(path.is_file() for path in required):
        raise ValueError("Pass the ios folder from your complete PrivMsg download.")
    if old.exists() and new.exists():
        raise ValueError("Both Resources and WebContent exist. No files were changed.")
    if not old.is_dir():
        if new.is_dir():
            print("This project already uses WebContent. No source changes are needed.")
            return
        raise ValueError("The bundled web content was not found. No files were changed.")
    if old.is_symlink():
        raise ValueError("Resources must be the original project folder, not a symbolic link.")

    # Check all replacements before touching the existing project.
    edits = {}
    for name, pairs in REPLACEMENTS.items():
        path = root / name
        text = path.read_text()
        for before, after in pairs:
            if before not in text:
                raise ValueError(f"Unexpected contents in {name}; no files were changed.")
            text = text.replace(before, after)
        edits[path] = text

    backup = root / "Local" / ("BundleRepairBackup-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True)
    originals = list(edits) + [project]
    signing = root / "Local/Signing.json"
    if signing.is_file():
        originals.append(signing)
    for path in originals:
        saved = backup / path.relative_to(root)
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, saved)
    print(f"Original project files backed up to: {backup}", flush=True)

    try:
        old.rename(new)
        for path, text in edits.items():
            path.write_text(text)
        # The generator adopts the Team and bundle ID saved in Xcode.
        subprocess.run([sys.executable, str(root / "generate_project.py")], check=True)
        subprocess.run([sys.executable, str(root / "validate_project.py")], check=True)
    except Exception:
        if new.is_dir() and not old.exists():
            new.rename(old)
        for path in originals:
            shutil.copy2(backup / path.relative_to(root), path)
        raise
    print("Repaired the app bundle layout and preserved the saved signing choices.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ios_folder", type=Path)
    args = parser.parse_args()
    try:
        repair(args.ios_folder)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Repair failed: {error}\n")
    print("Open PrivMsg.xcodeproj, choose Product > Clean Build Folder (Shift-Command-K), then Run (Command-R).")


if __name__ == "__main__":
    main()
