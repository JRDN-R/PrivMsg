import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "validate_built_app", Path(__file__).resolve().parents[1] / "tools" / "validate_built_app.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuiltAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="PrivMsg bundle test ")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "PrivMsg.app"
        (self.app / "WebContent").mkdir(parents=True)
        for name in ("index.html", "enhancements.js", "clipboard.js", "native-bridge.js", "native-paste.js", "app-icon.png"):
            (self.app / "WebContent" / name).write_text("fixture")
        (self.app / "PrivMsg").write_bytes(b"simulated executable")
        self.info = dict(CFBundleIdentifier="com.jordanrapp.PrivMsg",
                         CFBundleExecutable="PrivMsg", CFBundlePackageType="APPL",
                         CFBundleVersion="1", CFBundleShortVersionString="1.0",
                         CFBundleSupportedPlatforms=["iPhoneSimulator"])
        self.write_info()
        self.extension = self.app / "PlugIns/PrivMsgShare.appex"
        self.extension.mkdir(parents=True)
        (self.extension / "PrivMsgShare").write_bytes(b"simulated extension executable")
        self.share_info = dict(self.info, CFBundleIdentifier="com.jordanrapp.PrivMsg.Share",
                               CFBundleExecutable="PrivMsgShare", CFBundlePackageType="XPC!",
                               NSExtension={"NSExtensionPointIdentifier": "com.apple.share-services",
                                            "NSExtensionPrincipalClass": "PrivMsgShare.ShareViewController"})
        self.write_share_info()

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))

    def write_share_info(self):
        (self.extension / "Info.plist").write_bytes(plistlib.dumps(self.share_info, fmt=plistlib.FMT_BINARY))

    def test_valid_flat_bundle(self):
        MODULE.validate(self.app)

    def test_resources_folder_is_rejected_even_with_valid_info_plist(self):
        (self.app / "Resources").mkdir()
        with self.assertRaisesRegex(ValueError, "Reserved folder"):
            MODULE.validate(self.app)

    def test_device_build_is_rejected_before_ad_hoc_signing(self):
        self.info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        self.write_info()
        with self.assertRaisesRegex(ValueError, "Only an iPhone Simulator"):
            MODULE.validate(self.app)

    def test_unexpanded_bundle_id_is_rejected(self):
        self.info["CFBundleIdentifier"] = "$(PRODUCT_BUNDLE_IDENTIFIER)"
        self.write_info()
        with self.assertRaisesRegex(ValueError, "unresolved"):
            MODULE.validate(self.app)

    def test_missing_web_content_is_rejected(self):
        for name in ("native-bridge.js", "native-paste.js"):
            with self.subTest(name=name):
                path = self.app / "WebContent" / name
                path.unlink()
                with self.assertRaisesRegex(ValueError, "Missing bundled web content"):
                    MODULE.validate(self.app)
                path.write_text("fixture")

    def test_missing_embedded_share_is_rejected(self):
        shutil.rmtree(self.extension)
        with self.assertRaisesRegex(ValueError, "Missing embedded Share extension"):
            MODULE.validate(self.app)

    def test_share_identity_must_match_host(self):
        self.share_info["CFBundleIdentifier"] = "com.jordanrapp.Other.Share"
        self.write_share_info()
        with self.assertRaisesRegex(ValueError, "identifier must match"):
            MODULE.validate(self.app)

    def test_share_version_must_match_host(self):
        self.share_info["CFBundleVersion"] = "2"
        self.write_share_info()
        with self.assertRaisesRegex(ValueError, "versions differ"):
            MODULE.validate(self.app)


if __name__ == "__main__":
    unittest.main()
