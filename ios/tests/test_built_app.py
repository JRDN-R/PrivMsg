import importlib.util
from pathlib import Path
import plistlib
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
        for name in ("index.html", "enhancements.js", "clipboard.js", "native-bridge.js"):
            (self.app / "WebContent" / name).write_text("fixture")
        (self.app / "PrivMsg").write_bytes(b"simulated executable")
        self.info = dict(CFBundleIdentifier="com.jordanrapp.PrivMsg",
                         CFBundleExecutable="PrivMsg", CFBundlePackageType="APPL",
                         CFBundleVersion="1", CFBundleShortVersionString="1.0",
                         CFBundleSupportedPlatforms=["iPhoneSimulator"])
        self.write_info()

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))

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
        (self.app / "WebContent" / "native-bridge.js").unlink()
        with self.assertRaisesRegex(ValueError, "Missing bundled web content"):
            MODULE.validate(self.app)


if __name__ == "__main__":
    unittest.main()
