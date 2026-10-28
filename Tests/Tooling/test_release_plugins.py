"""Exercise official Plugin release packaging against disposable packages and a faked release source."""

import contextlib
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

    def released_versions(self, plugin_id):
        prefix = f"{plugin_id}/v"
        return [tag.removeprefix(prefix) for tag, _ in self.assets if tag.startswith(prefix)]


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

    def test_a_renamed_package_folder_counts_as_changed_contents(self):
        key, asset = self.published(self.spotify)
        self.spotify.rename(self.plugins / "SpotifyPlayer.spinnetplugin")
        with self.assertRaisesRegex(release.ReleaseError, "SpotifyPlayer.spinnetplugin/manifest.json"):
            release.plan(self.plugins, FakeReleases({key: asset}), REPOSITORY)

    def test_a_version_not_higher_than_the_highest_released_one_is_refused(self):
        _, asset = self.published(self.spotify)
        name = release.asset_name("com.spinnet.external.spotify")
        released = FakeReleases({("com.spinnet.external.spotify/v1.10.0", name): asset})
        for version in ("1.9.0", "1.10.0-rc.1", "0.1.0"):
            with self.subTest(version):
                manifest = self.manifest(self.spotify)
                manifest["version"] = version
                self.write_manifest(self.spotify, manifest)
                with self.assertRaisesRegex(release.ReleaseError, "1.10.0"):
                    release.plan(self.plugins, released, REPOSITORY)
        manifest["version"] = "1.10.1-beta.2"
        self.write_manifest(self.spotify, manifest)
        planned = release.plan(self.plugins, released, REPOSITORY)
        self.assertIn("com.spinnet.external.spotify/v1.10.1-beta.2", [item.tag for item in planned])

    def test_semver_precedence_orders_prereleases_below_their_release(self):
        ordered = ["1.0.0-0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                   "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.2.0", "1.10.0", "2.0.0"]
        self.assertEqual(sorted(reversed(ordered), key=release.semver_key), ordered)

    def test_only_plans_the_named_plugins_and_asks_about_nothing_else(self):
        source = FakeReleases()
        plan = release.plan(self.plugins, source, REPOSITORY, only=["com.spinnet.external.spotify"])
        self.assertEqual([item.tag for item in plan], ["com.spinnet.external.spotify/v1.2.0"])
        self.assertEqual(source.asked, [("com.spinnet.external.spotify/v1.2.0",
                                         "com.spinnet.external.spotify.spinnetplugin.zip")])

    def test_only_refuses_an_id_no_package_has(self):
        with self.assertRaisesRegex(release.ReleaseError, "com.spinnet.missing"):
            release.plan(self.plugins, FakeReleases(), REPOSITORY, only=["com.spinnet.missing"])

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


class FakeGitHub:
    """The `gh` CLI answering for a repository's tags, releases and asset downloads."""

    def __init__(self, tags=(), releases=(), downloads=None):
        self.tags, self.releases, self.downloads = list(tags), list(releases), dict(downloads or {})
        self.calls = []

    def __call__(self, *arguments, binary=False):
        self.calls.append(arguments)
        if "--jq" in arguments and "matching-refs" in arguments[2]:
            return "".join(f"refs/tags/{tag}\n" for tag in self.tags)
        if "--jq" in arguments and arguments[2].endswith("/releases"):
            return "".join(json.dumps(release) + "\n" for release in self.releases)
        if arguments[:2] == ("release", "create"):
            return ""
        asset_id = int(arguments[-1].rsplit("/", 1)[1])
        return self.downloads[asset_id]


def github_release(tag, assets=(), draft=False, prerelease=False):
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [{"id": asset_id, "name": name} for asset_id, name in assets]}


class BlockedReleases(DisposablePlugins):
    SPOTIFY = "com.spinnet.external.spotify/v1.2.0"
    SPOTIFY_ASSET = "com.spinnet.external.spotify.spinnetplugin.zip"
    CUT = "com.spinnet.builtin.cut/v1.0.0"

    def test_a_draft_a_tag_without_a_release_and_a_missing_asset_each_block_only_their_plugin(self):
        cases = {
            "draft": FakeGitHub(tags=[self.SPOTIFY], releases=[
                github_release(self.SPOTIFY, [(7, self.SPOTIFY_ASSET)], draft=True)]),
            "without a release": FakeGitHub(tags=[self.SPOTIFY]),
            "no asset": FakeGitHub(tags=[self.SPOTIFY], releases=[github_release(self.SPOTIFY, [(7, "other.zip")])]),
        }
        for reason, gh in cases.items():
            with self.subTest(reason):
                plan = release.plan(self.plugins, release.GitHubReleases(REPOSITORY, gh=gh), REPOSITORY)
                self.assertEqual({item.tag: item.blocked is not None for item in plan}, {self.CUT: False, self.SPOTIFY: True})
                blocked = next(item for item in plan if item.blocked)
                self.assertIn(reason, blocked.blocked)

    def test_released_versions_are_the_published_releases_of_that_plugin_only(self):
        gh = FakeGitHub(tags=[self.SPOTIFY, "com.spinnet.external.spotify/v2.0.0", "com.spinnet.builtin.cut/v9.0.0"],
                        releases=[github_release(self.SPOTIFY, [(7, self.SPOTIFY_ASSET)]),
                                  github_release("com.spinnet.external.spotify/v2.0.0", draft=True),
                                  github_release("com.spinnet.external.spotify/v1.5.0-beta", prerelease=True),
                                  github_release("com.spinnet.builtin.cut/v9.0.0")])
        versions = release.GitHubReleases(REPOSITORY, gh=gh).released_versions("com.spinnet.external.spotify")
        self.assertEqual(sorted(versions), ["1.2.0", "1.5.0-beta"])

    def test_publish_releases_the_others_and_exits_with_failure_naming_the_blocked_plugin(self):
        gh = FakeGitHub(tags=[self.SPOTIFY])
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = release.main(["publish", "--plugins", str(self.plugins), "--out", str(Path(self.temporary.name) / "dist")],
                                  gh=gh, target=lambda plugins: "0" * 40)
        self.assertEqual(status, 1)
        created = [call[2] for call in gh.calls if call[:2] == ("release", "create")]
        self.assertEqual(created, [self.CUT])
        self.assertIn(self.SPOTIFY, errors.getvalue())
        self.assertIn("blocked", output.getvalue())


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


class CleanTarget(DisposablePlugins):
    """`publish` releases a commit, so the Plugins it builds must be exactly what git tracks."""

    def setUp(self):
        super().setUp()
        self.repository = Path(self.temporary.name)
        (self.repository / ".gitignore").write_text(".DS_Store\n*.local\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "Plugins")

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repository), *arguments],
                              capture_output=True, text=True, check=True).stdout

    def test_a_committed_checkout_with_only_finder_junk_targets_head(self):
        (self.spotify / ".DS_Store").write_bytes(b"junk")
        self.assertEqual(release.clean_target(self.plugins), self.git("rev-parse", "HEAD").strip())

    def test_an_ignored_file_in_a_package_is_refused(self):
        (self.spotify / "settings.local").write_text("not committed")
        with self.assertRaisesRegex(release.ReleaseError, "settings.local"):
            release.clean_target(self.plugins)

    def test_an_untracked_or_changed_file_is_refused(self):
        (self.spotify / "added.js").write_text("// added\n")
        with self.assertRaisesRegex(release.ReleaseError, "added.js"):
            release.clean_target(self.plugins)


class GitHubReleaseFlags(DisposablePlugins):
    def created_with(self, version):
        manifest = self.manifest(self.spotify)
        manifest["version"] = version
        self.write_manifest(self.spotify, manifest)
        gh = FakeGitHub()
        planned = release.plan(self.plugins, FakeReleases(), REPOSITORY, only=["com.spinnet.external.spotify"])
        with contextlib.redirect_stdout(io.StringIO()):
            release.publish(planned, release.GitHubPublisher(REPOSITORY, gh=gh), "0" * 40,
                            Path(self.temporary.name) / "dist")
        (call,) = [call for call in gh.calls if call[:2] == ("release", "create")]
        return call

    def test_a_release_is_never_marked_latest_and_only_a_prerelease_version_is_marked_prerelease(self):
        stable = self.created_with("1.3.0")
        self.assertIn("--latest=false", stable)
        self.assertNotIn("--prerelease", stable)
        prerelease = self.created_with("1.3.0-beta.1")
        self.assertIn("--latest=false", prerelease)
        self.assertIn("--prerelease", prerelease)


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

    def test_only_builds_just_the_named_plugins_and_may_be_repeated(self):
        out = Path(self.temporary.name) / "dist"
        result = self.run_tool("build", "--plugins", str(self.plugins), "--out", str(out),
                               "--only", "com.spinnet.external.spotify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in out.iterdir()], ["com.spinnet.external.spotify.spinnetplugin.zip"])
        both = Path(self.temporary.name) / "both"
        result = self.run_tool("build", "--plugins", str(self.plugins), "--out", str(both),
                               "--only", "com.spinnet.external.spotify", "--only", "com.spinnet.builtin.cut")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(both.iterdir())), 2)

    def test_plan_and_publish_accept_only(self):
        for command in ("plan", "publish"):
            result = self.run_tool(command, "--help")
            self.assertIn("--only", result.stdout)

    def test_build_refuses_a_package_that_breaks_the_update_source_rules(self):
        manifest = json.loads((self.spotify / "manifest.json").read_text())
        del manifest["update_source"]
        (self.spotify / "manifest.json").write_text(json.dumps(manifest))
        result = self.run_tool("build", "--plugins", str(self.plugins), "--out", str(Path(self.temporary.name) / "dist"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update_source", result.stderr)


if __name__ == "__main__":
    unittest.main()
