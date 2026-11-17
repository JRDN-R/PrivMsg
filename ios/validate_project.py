#!/usr/bin/env python3
"""Check project references and resources. This does not compile Swift."""
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent


def parse_project(text):
    """Parse the generated OpenStep plist (also tolerates Xcode comments)."""
    tokens = re.findall(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}();=,]|[^\s{}();=,"]+', text)
    tokens = [token for token in tokens if not token.startswith(("//", "/*"))]
    position = 0

    def take(expected=None):
        nonlocal position
        if position >= len(tokens):
            raise ValueError("Unexpected end of project file")
        token = tokens[position]
        position += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected}, found {token}")
        return token

    def parse():
        token = take()
        if token == "{":
            result = {}
            while tokens[position] != "}":
                key = parse()
                take("=")
                if key in result:
                    raise ValueError(f"Duplicate project key: {key}")
                result[key] = parse()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while tokens[position] != ")":
                result.append(parse())
                if tokens[position] == ",":
                    take(",")
                elif tokens[position] != ")":
                    raise ValueError("Missing array separator")
            take(")")
            return result
        return json.loads(token) if token.startswith('"') else token

    result = parse()
    if position != len(tokens):
        raise ValueError("Unexpected tokens after project root")
    return result


def validate(root=ROOT):
    project = root / "PrivMsg.xcodeproj"
    tree = parse_project((project / "project.pbxproj").read_text())
    objects = tree["objects"]
    assert objects[tree["rootObject"]]["isa"] == "PBXProject", "Invalid root project"

    def check_references(value):
        if isinstance(value, dict):
            for nested in value.values():
                check_references(nested)
        elif isinstance(value, list):
            for nested in value:
                check_references(nested)
        elif isinstance(value, str) and re.fullmatch(r"[A-F0-9]{24}", value):
            assert value in objects, f"Missing project object: {value}"

    check_references(objects)
    targets = [(ident, obj) for ident, obj in objects.items() if obj["isa"] == "PBXNativeTarget"]
    assert len(targets) == 1, "Expected one Personal Team compatible app target"
    target_id, target = targets[0]
    assert target["productType"] == "com.apple.product-type.application"
    configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
    bundles, teams = set(), set()
    for ident in configs:
        settings = objects[ident]["buildSettings"]
        bundles.add(settings["PRODUCT_BUNDLE_IDENTIFIER"])
        teams.add(settings.get("DEVELOPMENT_TEAM", ""))
        assert settings["CODE_SIGN_STYLE"] == "Automatic", "Automatic signing is required"
        assert "CODE_SIGN_ENTITLEMENTS" not in settings, "Unexpected paid or shared-container capabilities"
        assert settings["INFOPLIST_FILE"] == "PrivMsg/Info.plist"
    assert len(bundles) == len(teams) == 1, "Debug and Release signing must match"
    assert all(not team or re.fullmatch(r"[A-Z0-9]{10}", team) for team in teams)

    app = root / "PrivMsg"
    actual_swift = {p.relative_to(app).as_posix() for p in app.rglob("*.swift")}
    referenced_swift = {obj["path"] for obj in objects.values() if obj["isa"] == "PBXFileReference" and obj.get("lastKnownFileType") == "sourcecode.swift"}
    assert actual_swift and actual_swift == referenced_swift, "Missing or stale Swift file references; rerun generator"
    phase_ids = target["buildPhases"]
    source_phase = next(objects[ident] for ident in phase_ids if objects[ident]["isa"] == "PBXSourcesBuildPhase")
    compiled_swift = {objects[objects[ident]["fileRef"]]["path"] for ident in source_phase["files"]}
    assert compiled_swift == actual_swift, "Not all Swift files are compiled"
    resource_phase = next(objects[ident] for ident in phase_ids if objects[ident]["isa"] == "PBXResourcesBuildPhase")
    copied_resources = {objects[objects[ident]["fileRef"]]["path"] for ident in resource_phase["files"]}
    assert "Assets.xcassets" in copied_resources, "App icons are not in the resource phase"
    assert "Resources" not in copied_resources, "iOS app bundles cannot contain a top-level Resources folder"
    assert not (app / "Resources").exists(), "Rename the reserved Resources folder to WebContent"
    assert (app / "WebContent").is_dir(), "Bundled web content is missing"
    assert "WebContent" in copied_resources, "Bundled web files are missing from resources"
    for path in referenced_swift | copied_resources | {"Info.plist"}:
        assert (app / path).exists(), f"Missing app file: {path}"

    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    assert info.get("CFBundleIdentifier") == "$(PRODUCT_BUNDLE_IDENTIFIER)", "Info.plist must inherit the selected bundle ID"
    assert info.get("CFBundleExecutable") == "$(EXECUTABLE_NAME)", "Info.plist must identify the built executable"
    icon_set = app / "Assets.xcassets" / "AppIcon.appiconset"
    icons = json.loads((icon_set / "Contents.json").read_text())["images"]
    has_marketing_icon = False
    for image in icons:
        if not image.get("filename"):
            continue
        filename = image["filename"]
        assert Path(filename).name == filename, "Icon filename must be local to its asset set"
        data = (icon_set / filename).read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {filename}"
        width, height = struct.unpack(">II", data[16:24])
        if width == height == 1024:
            has_marketing_icon = True
    assert has_marketing_icon, "A 1024px app icon is required"
    scheme = ET.parse(project / "xcshareddata" / "xcschemes" / "PrivMsg.xcscheme").getroot()
    refs = scheme.findall(".//BuildableReference")
    assert refs and all(ref.get("BlueprintIdentifier") == target_id for ref in refs), "Scheme targets do not match"
    ET.parse(project / "project.xcworkspace" / "contents.xcworkspacedata")
    print(f"Verified {len(actual_swift)} Swift files, app resources, icon, signing, project references and shared scheme.")
    print("Swift compilation and device installation still require Xcode on macOS.")


if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, KeyError, ValueError, OSError, IndexError, ET.ParseError) as error:
        print(f"Project validation failed: {error}", file=sys.stderr)
        sys.exit(1)
