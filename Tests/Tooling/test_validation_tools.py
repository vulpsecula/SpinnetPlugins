"""Exercise the generator CLI on disposable copies, including failure and write boundaries."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class GeneratedEntryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        shutil.copytree(ROOT / "Sources/Homebrew", self.root / "Sources/Homebrew")
        self.package = self.root / "Plugins/Homebrew.spinnetplugin"
        shutil.copytree(ROOT / "Plugins/Homebrew.spinnetplugin", self.package)
        self.script = self.root / "Sources/Homebrew/scripts/build.py"

    def run_generator(self, *arguments):
        return subprocess.run([sys.executable, str(self.script), *arguments],
                              cwd=self.temporary.name, capture_output=True, text=True)

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.root.rglob("*") if path.is_file()}

    def test_check_passes_from_an_unrelated_directory_without_rewriting_files(self):
        manifest = self.package / "manifest.json"
        data = json.loads(manifest.read_text())
        data["commands"][0]["title"] = "A translated title is not a generated entry identity"
        manifest.write_text(json.dumps(data))
        before = self.snapshot()
        result = self.run_generator("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_check_reports_missing_extra_and_drifted_scripts_without_repairing_them(self):
        (self.package / "brew-search.js").unlink()
        (self.package / "brew-retired.js").write_text("old entry")
        with (self.package / "brew-installed.js").open("ab") as stream:
            stream.write(b"\n// drift\n")
        before = self.snapshot()
        result = self.run_generator("--check")
        self.assertNotEqual(result.returncode, 0)
        for text in ("Missing generated script: brew-search.js", "Retired generated script remains: brew-retired.js", "Generated script differs: brew-installed.js"):
            self.assertIn(text, result.stderr)
        self.assertEqual(self.snapshot(), before)
        repaired = self.run_generator()
        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        self.assertFalse((self.package / "brew-retired.js").exists())
        self.assertEqual(self.run_generator("--check").returncode, 0)

    def test_check_rejects_swapped_manifest_id_to_script_mapping(self):
        manifest = self.package / "manifest.json"
        data = json.loads(manifest.read_text())
        first, second = data["commands"][:2]
        first["script"], second["script"] = second["script"], first["script"]
        manifest.write_text(json.dumps(data))
        before = self.snapshot()
        result = self.run_generator("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Manifest Command IDs/scripts differ", result.stderr)
        self.assertEqual(self.snapshot(), before)


class CoffeeSchemaChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.answers = Path(self.temporary.name) / "answers"
        self.answers.mkdir()
        self.script = ROOT / "script/check_coffee_answers.py"

    def check(self, *arguments, script=None):
        return subprocess.run(["uv", "run", "--locked", str(script or self.script),
                               "--answers-dir", str(self.answers), *arguments],
                              cwd=self.temporary.name, capture_output=True, text=True)

    def test_missing_exports_are_an_error(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("coffee.open.json", result.stderr)

    def test_invalid_page_and_requested_operation_input_fail_without_changing_exports(self):
        path = self.answers / "coffee.open.json"
        for answer in ({"page": {"id": "broken"}},
                       {"operation": {"perform": "system.keepAwake", "input": {"mode": "not-a-mode"}}}):
            with self.subTest(answer=answer):
                path.write_text(json.dumps(answer))
                before = (path.read_bytes(), path.stat().st_mtime_ns)
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("coffee.open.json", result.stderr)
                self.assertIn("Failed validating", result.stderr)
                self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)

    def test_default_rejects_a_checkout_at_a_different_revision(self):
        root = Path(self.temporary.name) / "checkout"
        (root / "script").mkdir(parents=True)
        for name in ("check_coffee_answers.py", "check_coffee_answers.py.lock"):
            shutil.copy2(ROOT / "script" / name, root / "script" / name)
        pin = json.loads((ROOT / "Package.resolved").read_text())
        next(item for item in pin["pins"] if item["identity"] == "spinnet")["state"]["revision"] = "0" * 40
        (root / "Package.resolved").write_text(json.dumps(pin))
        (root / ".build/checkouts").mkdir(parents=True)
        (root / ".build/checkouts/Spinnet").symlink_to(ROOT / ".build/checkouts/Spinnet", target_is_directory=True)
        result = self.check(script=root / "script/check_coffee_answers.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from Package.resolved", result.stderr)


if __name__ == "__main__":
    unittest.main()
