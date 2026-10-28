"""Exercise official Plugin release packaging against disposable packages and a faked release source."""

import importlib.util
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "vulpsecula/SpinnetPlugins"

# The Host's update_source rules (Spinnet PluginAPI/reference/update-source.md).
TAG_SAFE_ID = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")
UPDATE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$")


class OfficialManifests(unittest.TestCase):
    def test_every_manifest_declares_this_repository_with_a_tag_safe_id_and_release_version(self):
        manifests = sorted((ROOT / "Plugins").glob("*.spinnetplugin/manifest.json"))
        self.assertEqual(len(manifests), 22)
        for path in manifests:
            manifest = json.loads(path.read_text())
            with self.subTest(package=path.parent.name):
                self.assertEqual(manifest.get("update_source"), {"github": REPOSITORY})
                self.assertRegex(manifest["id"], TAG_SAFE_ID)
                self.assertNotIn("..", manifest["id"])
                self.assertFalse(manifest["id"].endswith(".lock"))
                self.assertRegex(manifest["version"], UPDATE_VERSION)


if __name__ == "__main__":
    unittest.main()
