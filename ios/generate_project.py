#!/usr/bin/env python3
"""Generate PrivMsg.xcodeproj with Python's standard library, no XcodeGen needed."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
DEFAULT_BUNDLE = "com.jordanrapp.PrivMsg"


def object_id(name: str) -> str:
    return hashlib.sha256(("PrivMsg:" + name).encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def write_if_changed(path: Path, text: str):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def serialize(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        body = "\n".join(f"{indent}\t{quote(key)} = {serialize(item, level + 1)};" for key, item in value.items())
        return "{\n" + body + "\n" + indent + "}"
    if isinstance(value, list):
        body = "\n".join(f"{indent}\t{serialize(item, level + 1)}," for item in value)
        return "(\n" + body + "\n" + indent + ")"
    if isinstance(value, int):
        return str(value)
    return quote(value)


def current_signing(root=ROOT):
    """Adopt Xcode's visible selections before regenerating the project."""
    saved = {}
    settings = root / "Local" / "Signing.json"
    if settings.exists():
        saved = json.loads(settings.read_text())
    project = root / "PrivMsg.xcodeproj" / "project.pbxproj"
    if project.exists():
        text = project.read_text()
        choices = {}
        for setting, key in [("DEVELOPMENT_TEAM", "team"), ("PRODUCT_BUNDLE_IDENTIFIER", "bundle")]:
            pattern = rf'"?{setting}"?\s*=\s*(?:"([^"\n]*)"|([^;\s]+))\s*;'
            values = {quoted or bare for quoted, bare in re.findall(pattern, text)}
            values.discard("")
            if len(values) == 1:
                choices[key] = next(iter(values))
            elif len(values) > 1:
                raise ValueError(f"Different {setting} values are selected in Xcode. Use the same value for Debug and Release.")
        # A new release ships an unsigned stock project. Its placeholder bundle
        # must not replace a custom identity saved in the installer's shared Local
        # directory. Real selections made in Xcode still take precedence.
        is_stock_project = not choices.get("team") and choices.get("bundle") == DEFAULT_BUNDLE
        if not is_stock_project:
            saved.update(choices)
    return saved


def project_objects(source_names, team, bundle, has_resources):
    objects = {}

    def add(object_name, **values):
        ident = object_id(object_name)
        objects[ident] = values
        return ident

    source_refs, source_builds = [], []
    for name in source_names:
        ref = add("source:" + name, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=name, sourceTree="<group>")
        source_refs.append(ref)
        source_builds.append(add("build:" + name, isa="PBXBuildFile", fileRef=ref))

    plist_ref = add("Info.plist", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>")
    asset_ref = add("Assets.xcassets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
    resource_refs = [asset_ref]
    resource_builds = [add("build:assets", isa="PBXBuildFile", fileRef=asset_ref)]
    if has_resources:
        resource_ref = add("WebContent", isa="PBXFileReference", lastKnownFileType="folder", path="WebContent", sourceTree="<group>")
        resource_refs.append(resource_ref)
        resource_builds.append(add("build:resources", isa="PBXBuildFile", fileRef=resource_ref))
    product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="PrivMsg.app", sourceTree="BUILT_PRODUCTS_DIR")
    app_group = add("app-group", isa="PBXGroup", children=source_refs + [plist_ref] + resource_refs, path="PrivMsg", sourceTree="<group>")
    products_group = add("products-group", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
    main_group = add("main-group", isa="PBXGroup", children=[app_group, products_group], sourceTree="<group>")
    sources = add("sources-phase", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
    frameworks = add("frameworks-phase", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    resources = add("resources-phase", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    project_configs, target_configs = [], []
    for name in ["Debug", "Release"]:
        project_settings = {
            "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
            "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO",
            "ONLY_ACTIVE_ARCH": "YES" if name == "Debug" else "NO",
        }
        target_settings = {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": team,
            "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0.0",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "PrivMsg/Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": bundle, "PRODUCT_NAME": "$(TARGET_NAME)",
            "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal",
            "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        }
        if name == "Debug":
            target_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        project_configs.append(add("project-config:" + name, isa="XCBuildConfiguration", buildSettings=project_settings, name=name))
        target_configs.append(add("target-config:" + name, isa="XCBuildConfiguration", buildSettings=target_settings, name=name))
    project_config_list = add("project-config-list", isa="XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target_config_list = add("target-config-list", isa="XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = add("target", isa="PBXNativeTarget", buildConfigurationList=target_config_list, buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[], name="PrivMsg", productName="PrivMsg", productReference=product, productType="com.apple.product-type.application")
    attributes = {"LastUpgradeCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic"}}}
    project = add("project", isa="PBXProject", attributes=attributes, buildConfigurationList=project_config_list, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=products_group, projectDirPath="", projectRoot="", targets=[target])
    return {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}


def generate(team=None, bundle=None, root=ROOT):
    saved = current_signing(root)
    team = saved.get("team", "") if team is None else team
    bundle = saved.get("bundle", DEFAULT_BUNDLE) if bundle is None else bundle
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Team ID must be the 10-character ID shown by Xcode (uppercase letters/numbers).")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", bundle) or "." not in bundle or ".." in bundle:
        raise ValueError("Bundle identifier must be a reverse-domain identifier such as com.jordanrapp.PrivMsg.")
    app = root / "PrivMsg"
    if (app / "Resources").exists():
        raise ValueError("iOS app bundles cannot contain a Resources folder. Run tools/repair_bundle_layout.py for this older project.")
    sources = sorted(p.relative_to(app).as_posix() for p in app.rglob("*.swift"))
    if not sources:
        raise ValueError("No Swift app sources were found. Extract the entire PrivMsg package before running this script.")
    for required in [app / "Info.plist", app / "Assets.xcassets"]:
        if not required.exists():
            raise ValueError(f"Missing required app resource: {required}")
    tree = project_objects(sources, team, bundle, (app / "WebContent").is_dir())
    project = root / "PrivMsg.xcodeproj"
    project.mkdir(exist_ok=True)
    write_if_changed(project / "project.pbxproj", "// !$*UTF8*$!\n" + serialize(tree) + "\n")
    workspace = project / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    write_if_changed(workspace / "contents.xcworkspacedata", '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
    scheme_dir = project / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{object_id("target")}" BuildableName="PrivMsg.app" BlueprintName="PrivMsg" ReferencedContainer="container:PrivMsg.xcodeproj"/>'
    write_if_changed(scheme_dir / "PrivMsg.xcscheme", f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    local = root / "Local"
    local.mkdir(exist_ok=True)
    settings_path = local / "Signing.json"
    temporary = local / "Signing.json.tmp"
    temporary.write_text(json.dumps({"team": team, "bundle": bundle}, indent=2) + "\n")
    os.replace(temporary, settings_path)
    return project, tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", help="Apple development Team ID")
    parser.add_argument("--bundle-id", help="Keep the same ID when renewing an installed app")
    args = parser.parse_args()
    try:
        project, _ = generate(args.team, args.bundle_id)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"Could not generate PrivMsg: {error}\n")
    print(f"Generated {project}")
    print("Personal Team compatible: one app target, no paid capabilities.")


if __name__ == "__main__":
    main()
