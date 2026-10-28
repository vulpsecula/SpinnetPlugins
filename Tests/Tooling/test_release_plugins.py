"""Exercise official Plugin release packaging against disposable packages and a faked release source."""

import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "vulpsecula/SpinnetPlugins"

# The Host's update_source rules (Spinnet PluginAPI/reference/update-source.md).
TAG_SAFE_ID = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")
UPDATE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$")


def load_release_tool():
    spec = importlib.util.spec_from_file_location("release_plugins", ROOT / "script/release_plugins.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_release_tool()


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


    def test_each_asset_holds_exactly_the_files_git_tracks_in_its_package_including_notices(self):
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "Plugins"],
                                 capture_output=True, text=True, check=True).stdout.split("\0")
        expected = {path.removeprefix("Plugins/") for path in tracked if path}
        archived = set()
        for package in sorted((ROOT / "Plugins").glob("*.spinnetplugin")):
            with zipfile.ZipFile(io.BytesIO(release.build_archive(package))) as archive:
                archived |= {name for name in archive.namelist() if not name.endswith("/")}
        self.assertEqual(archived, expected)
        self.assertEqual(len({name for name in archived if name.endswith("/LICENSE")}), 22)
        self.assertIn("Spotify.spinnetplugin/NOTICE", archived)


class ReleaseNaming(unittest.TestCase):
    def test_tag_and_asset_follow_the_host_contract(self):
        self.assertEqual(release.release_tag("com.spinnet.bob", "1.1.0"), "com.spinnet.bob/v1.1.0")
        self.assertEqual(release.asset_name("com.spinnet.bob"), "com.spinnet.bob.spinnetplugin.zip")


class DisposablePlugins(unittest.TestCase):
    """A disposable Plugins directory holding copies of real packages."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.plugins = Path(self.temporary.name) / "Plugins"
        for name in ("Spotify", "Cut"):
            shutil.copytree(ROOT / f"Plugins/{name}.spinnetplugin", self.plugins / f"{name}.spinnetplugin")
        self.spotify = self.plugins / "Spotify.spinnetplugin"

    def manifest(self, package):
        return json.loads((package / "manifest.json").read_text())

    def write_manifest(self, package, manifest):
        (package / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def published(self, package):
        """A release of the package as it is now, zipped by another tool."""
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", zipfile.ZIP_STORED) as archive:
            for path in sorted(package.rglob("*"), reverse=True):
                archive.write(path, f"{package.name}/{path.relative_to(package).as_posix()}")
            archive.writestr("__MACOSX/._manifest.json", b"sidecar")
        manifest = self.manifest(package)
        return (release.release_tag(manifest["id"], manifest["version"]), release.asset_name(manifest["id"])), output.getvalue()


class DeterministicArchives(DisposablePlugins):
    def test_the_archive_holds_exactly_the_package_folder_without_junk(self):
        (self.spotify / ".DS_Store").write_bytes(b"junk")
        (self.spotify / "nested").mkdir()
        (self.spotify / "nested/data.json").write_text("{}")
        (self.spotify / "nested/._data.json").write_bytes(b"resource fork")
        archive = zipfile.ZipFile(io.BytesIO(release.build_archive(self.spotify)))
        names = [info.filename for info in archive.infolist()]
        self.assertEqual(names, [
            "Spotify.spinnetplugin/", "Spotify.spinnetplugin/LICENSE", "Spotify.spinnetplugin/NOTICE",
            "Spotify.spinnetplugin/actions.js", "Spotify.spinnetplugin/manifest.json",
            "Spotify.spinnetplugin/nested/", "Spotify.spinnetplugin/nested/data.json",
        ])
        self.assertEqual(archive.read("Spotify.spinnetplugin/NOTICE"), (self.spotify / "NOTICE").read_bytes())
        for info in archive.infolist():
            self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
            self.assertEqual(info.create_system, 3)
            if info.is_dir():
                self.assertEqual(info.external_attr >> 16, 0o40755)
            else:
                self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                self.assertEqual(info.external_attr >> 16, 0o100644)

    def test_the_same_package_builds_the_same_bytes_whatever_its_timestamps_and_modes(self):
        first = release.build_archive(self.spotify)
        script = self.spotify / "actions.js"
        script.chmod(0o755)
        os.utime(script, (0, 0))
        (self.spotify / ".DS_Store").write_bytes(b"junk")
        self.assertEqual(release.build_archive(self.spotify), first)

    def test_a_link_inside_a_package_is_refused(self):
        (self.spotify / "link.js").symlink_to(self.spotify / "actions.js")
        with self.assertRaisesRegex(release.ReleaseError, "link.js"):
            release.build_archive(self.spotify)


class FakeReleases:
    """Published release assets by tag, as a GitHub repository would serve them."""

    def __init__(self, assets=None):
        self.assets = dict(assets or {})
        self.asked = []

    def released_asset(self, tag, name):
        self.asked.append((tag, name))
        return self.assets.get((tag, name))


class ReleasePlans(DisposablePlugins):
    def test_versions_without_a_release_are_planned_with_their_tag_and_asset(self):
        plan = release.plan(self.plugins, FakeReleases(), REPOSITORY)
        self.assertEqual([(item.tag, item.asset, item.released) for item in plan], [
            ("com.spinnet.builtin.cut/v1.0.0", "com.spinnet.builtin.cut.spinnetplugin.zip", False),
            ("com.spinnet.external.spotify/v1.2.0", "com.spinnet.external.spotify.spinnetplugin.zip", False),
        ])
        self.assertEqual(plan[1].archive, release.build_archive(self.spotify))

    def test_a_released_version_with_the_same_contents_is_skipped(self):
        key, asset = self.published(self.spotify)
        plan = release.plan(self.plugins, FakeReleases({key: asset}), REPOSITORY)
        self.assertEqual({item.tag: item.released for item in plan}, {
            "com.spinnet.builtin.cut/v1.0.0": False, "com.spinnet.external.spotify/v1.2.0": True,
        })

    def test_changed_contents_without_a_version_bump_are_refused(self):
        key, asset = self.published(self.spotify)
        with (self.spotify / "actions.js").open("a") as script:
            script.write("// changed\n")
        (self.spotify / "added.js").write_text("// added\n")
        with self.assertRaises(release.ReleaseError) as refusal:
            release.plan(self.plugins, FakeReleases({key: asset}), REPOSITORY)
        message = str(refusal.exception)
        for text in ("com.spinnet.external.spotify/v1.2.0", "actions.js", "added.js", "bump its version"):
            self.assertIn(text, message)

    def test_a_bumped_version_is_planned_after_an_earlier_release(self):
        key, asset = self.published(self.spotify)
        manifest = self.manifest(self.spotify)
        manifest["version"] = "1.2.1"
        self.write_manifest(self.spotify, manifest)
        plan = release.plan(self.plugins, FakeReleases({key: asset}), REPOSITORY)
        self.assertIn(("com.spinnet.external.spotify/v1.2.1", False), [(item.tag, item.released) for item in plan])

    def test_a_manifest_that_breaks_the_update_source_rules_is_refused_before_any_lookup(self):
        cases = {
            "another repository": {"update_source": {"github": "someone/else"}},
            "no Update Source": {"update_source": None},
            "build metadata": {"version": "1.2.0+build.1"},
            "untaggable id": {"id": "com.spinnet.spotify.lock"},
        }
        original = self.manifest(self.spotify)
        for case, change in cases.items():
            with self.subTest(case):
                manifest = {**original, **change}
                self.write_manifest(self.spotify, {key: value for key, value in manifest.items() if value is not None})
                source = FakeReleases()
                with self.assertRaises(release.ReleaseError):
                    release.plan(self.plugins, source, REPOSITORY)
                self.assertEqual(source.asked, [])


class FakePublisher:
    def __init__(self):
        self.created = []

    def create(self, tag, asset, title, notes, target):
        self.created.append({"tag": tag, "asset": asset.name, "bytes": asset.read_bytes(), "title": title,
                             "notes": notes, "target": target})


class Publishing(DisposablePlugins):
    def test_only_unreleased_versions_are_published_at_the_target_commit(self):
        key, asset = self.published(self.spotify)
        publisher = FakePublisher()
        planned = release.plan(self.plugins, FakeReleases({key: asset}), REPOSITORY)
        release.publish(planned, publisher, "0123456789abcdef0123456789abcdef01234567", Path(self.temporary.name) / "dist")
        self.assertEqual(len(publisher.created), 1)
        created = publisher.created[0]
        self.assertEqual(created["tag"], "com.spinnet.builtin.cut/v1.0.0")
        self.assertEqual(created["asset"], "com.spinnet.builtin.cut.spinnetplugin.zip")
        self.assertEqual(created["bytes"], release.build_archive(self.plugins / "Cut.spinnetplugin"))
        self.assertEqual(created["title"], "Cut 1.0.0")
        self.assertIn("com.spinnet.builtin.cut", created["notes"])
        self.assertEqual(created["target"], "0123456789abcdef0123456789abcdef01234567")


class CommandLine(DisposablePlugins):
    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, "-I", str(ROOT / "script/release_plugins.py"), *arguments],
                              cwd=self.temporary.name, capture_output=True, text=True)

    def test_build_writes_each_asset_under_its_release_name_without_asking_github(self):
        out = Path(self.temporary.name) / "dist"
        result = self.run_tool("build", "--plugins", str(self.plugins), "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.name for path in out.iterdir()), [
            "com.spinnet.builtin.cut.spinnetplugin.zip", "com.spinnet.external.spotify.spinnetplugin.zip"])
        self.assertEqual((out / "com.spinnet.external.spotify.spinnetplugin.zip").read_bytes(),
                         release.build_archive(self.spotify))

    def test_build_refuses_a_package_that_breaks_the_update_source_rules(self):
        manifest = json.loads((self.spotify / "manifest.json").read_text())
        del manifest["update_source"]
        (self.spotify / "manifest.json").write_text(json.dumps(manifest))
        result = self.run_tool("build", "--plugins", str(self.plugins), "--out", str(Path(self.temporary.name) / "dist"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update_source", result.stderr)


if __name__ == "__main__":
    unittest.main()
