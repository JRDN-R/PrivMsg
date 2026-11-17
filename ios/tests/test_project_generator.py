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


if __name__ == "__main__":
    unittest.main()
