import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "privmsg_project_generator", Path(__file__).resolve().parents[1] / "generate_project.py"
)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class SigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="privmsg-signing-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        app = self.root / "PrivMsg"
        app.mkdir()
        (app / "AppDelegate.swift").write_text("import UIKit\n")
        (app / "Info.plist").write_text("test fixture\n")
        (app / "Assets.xcassets").mkdir()

    def save_identity(self, team="ABCDE12345", bundle="com.jordanrapp.CustomPrivMsg"):
        local = self.root / "Local"
        local.mkdir(exist_ok=True)
        identity = {"team": team, "bundle": bundle}
        (local / "Signing.json").write_text(json.dumps(identity))
        return identity

    def stock_project(self):
        project = self.root / "PrivMsg.xcodeproj"
        project.mkdir(exist_ok=True)
        tree = generator.project_objects(["AppDelegate.swift"], "", generator.DEFAULT_BUNDLE, False)
        (project / "project.pbxproj").write_text(generator.serialize(tree))

    def test_saved_identity_survives_fresh_stock_release(self):
        saved = self.save_identity()
        self.stock_project()
        self.assertEqual(generator.current_signing(self.root), saved)
        generator.generate(root=self.root)
        self.assertEqual(json.loads((self.root / "Local" / "Signing.json").read_text()), saved)
        text = (self.root / "PrivMsg.xcodeproj" / "project.pbxproj").read_text()
        self.assertIn('"PRODUCT_BUNDLE_IDENTIFIER" = "com.jordanrapp.CustomPrivMsg"', text)

    def test_manual_xcode_selection_overrides_saved_identity(self):
        self.save_identity()
        self.stock_project()
        project = self.root / "PrivMsg.xcodeproj" / "project.pbxproj"
        project.write_text(project.read_text().replace('"DEVELOPMENT_TEAM" = ""', '"DEVELOPMENT_TEAM" = "ZYXWV98765"').replace(generator.DEFAULT_BUNDLE, "com.jordanrapp.ManualPrivMsg"))
        self.assertEqual(generator.current_signing(self.root), {"team": "ZYXWV98765", "bundle": "com.jordanrapp.ManualPrivMsg"})

    def test_explicit_bundle_override_can_restore_default(self):
        self.save_identity()
        self.stock_project()
        generator.generate(bundle=generator.DEFAULT_BUNDLE, root=self.root)
        self.assertEqual(json.loads((self.root / "Local" / "Signing.json").read_text())["bundle"], generator.DEFAULT_BUNDLE)

    def test_first_install_uses_default_without_saved_identity(self):
        self.stock_project()
        generator.generate(root=self.root)
        self.assertEqual(json.loads((self.root / "Local" / "Signing.json").read_text()), {"team": "", "bundle": generator.DEFAULT_BUNDLE})

    def test_custom_bundle_in_unsigned_xcode_project_is_adopted(self):
        self.save_identity()
        self.stock_project()
        project = self.root / "PrivMsg.xcodeproj" / "project.pbxproj"
        project.write_text(project.read_text().replace(generator.DEFAULT_BUNDLE, "com.jordanrapp.NewCustomID"))
        self.assertEqual(generator.current_signing(self.root), {"team": "ABCDE12345", "bundle": "com.jordanrapp.NewCustomID"})

    def test_web_content_has_safe_bundle_folder_name(self):
        (self.root / "PrivMsg" / "WebContent").mkdir()
        _, tree = generator.generate(root=self.root)
        folders = [obj["path"] for obj in tree["objects"].values()
                   if obj.get("isa") == "PBXFileReference" and obj.get("lastKnownFileType") == "folder"]
        self.assertEqual(folders, ["WebContent"])

    def test_reserved_resources_directory_is_rejected(self):
        (self.root / "PrivMsg" / "Resources").mkdir()
        with self.assertRaisesRegex(ValueError, "cannot contain a Resources folder"):
            generator.generate(root=self.root)

    def add_share(self):
        share = self.root / "PrivMsgShare"
        share.mkdir()
        (share / "ShareViewController.swift").write_text("import UIKit\n")
        (share / "Info.plist").write_text("fixture")

    def test_share_identifier_does_not_conflict_with_host_signing(self):
        self.add_share()
        identity = self.save_identity()
        generator.generate(root=self.root)
        self.assertEqual(generator.current_signing(self.root), identity)
        _, tree = generator.generate(root=self.root)
        objects = tree["objects"]
        app = objects[generator.object_id("target")]
        share = objects[generator.object_id("share-target")]
        self.assertEqual(objects[app["dependencies"][0]]["target"], generator.object_id("share-target"))
        for config in objects[share["buildConfigurationList"]]["buildConfigurations"]:
            settings = objects[config]["buildSettings"]
            self.assertEqual(settings["DEVELOPMENT_TEAM"], identity["team"])
            self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], identity["bundle"] + ".Share")
            self.assertEqual(settings["APPLICATION_EXTENSION_API_ONLY"], "YES")
            self.assertNotIn("CODE_SIGN_ENTITLEMENTS", settings)
        embed = objects[generator.object_id("embed-share-phase")]
        self.assertEqual(embed["dstSubfolderSpec"], 13)
        self.assertEqual(objects[objects[embed["files"][0]]["fileRef"]]["path"], "PrivMsgShare.appex")

    def test_host_xcode_choice_wins_when_extension_has_stale_team(self):
        self.add_share()
        self.save_identity()
        _, tree = generator.generate(root=self.root)
        objects = tree["objects"]
        host = objects[generator.object_id("target")]
        for config in objects[host["buildConfigurationList"]]["buildConfigurations"]:
            objects[config]["buildSettings"]["DEVELOPMENT_TEAM"] = "ZYXWV98765"
            objects[config]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.jordanrapp.ManualHost"
        (self.root / "PrivMsg.xcodeproj/project.pbxproj").write_text(generator.serialize(tree))
        self.assertEqual(generator.current_signing(self.root), {"team": "ZYXWV98765", "bundle": "com.jordanrapp.ManualHost"})
        _, updated = generator.generate(root=self.root)
        self.assertEqual(updated["objects"][generator.object_id("share-config:Debug")]["buildSettings"]["DEVELOPMENT_TEAM"], "ZYXWV98765")

    def test_mismatched_host_debug_release_still_rejected(self):
        self.add_share()
        _, tree = generator.generate(root=self.root)
        tree["objects"][generator.object_id("target-config:Debug")]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.jordanrapp.Other"
        (self.root / "PrivMsg.xcodeproj/project.pbxproj").write_text(generator.serialize(tree))
        with self.assertRaisesRegex(ValueError, "Different PRODUCT_BUNDLE_IDENTIFIER"):
            generator.current_signing(self.root)


if __name__ == "__main__":
    unittest.main()
