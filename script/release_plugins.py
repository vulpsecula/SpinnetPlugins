"""Package and publish each official Plugin version as its own GitHub Release.

Each package under Plugins/ is released as tag `<id>/v<version>` with the
asset `<id>.spinnetplugin.zip`, the names Spinnet's Update Source contract
defines. A version already released is compared with its published asset:
identical contents are skipped, and changed contents without a version bump
are refused. Existing tags and releases are never changed.

    build   --out DIR      build every asset without asking GitHub
    plan    [--out DIR]    list released and unreleased versions (a dry run)
    publish [--dry-run]    create a release at HEAD for every unreleased version

GitHub is reached through the `gh` CLI, authenticated by GH_TOKEN in CI.
"""

import argparse
from dataclasses import dataclass
import io
import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile


# Finder and resource-fork leftovers are never part of a package.
JUNK_NAMES = {".DS_Store", "__MACOSX", "Icon\r"}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)

# The Host's rules for a Plugin with an Update Source and its published
# bounds (Spinnet PluginAPI/reference/update-source.md).
TAG_SAFE_ID = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")
UPDATE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$")
MAXIMUM_PACKAGE_BYTES = 16 * 1024 * 1024
MAXIMUM_UNPACKED_BYTES = 64 * 1024 * 1024
MAXIMUM_ENTRIES = 2048

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "vulpsecula/SpinnetPlugins"


class ReleaseError(Exception):
    """A package that cannot be released as it is."""


def release_tag(plugin_id, version):
    """The tag the Host looks up for this Plugin version."""
    return f"{plugin_id}/v{version}"


def asset_name(plugin_id):
    """The release asset the Host downloads for this Plugin."""
    return f"{plugin_id}.spinnetplugin.zip"


def _is_junk(name):
    return name in JUNK_NAMES or name.startswith("._")


def package_entries(package):
    """The package's folders and files relative to its parent, sorted, without junk."""
    package = Path(package)
    entries = [(package.name + "/", None)]
    for path in sorted(package.rglob("*"), key=lambda path: path.relative_to(package).as_posix()):
        relative = path.relative_to(package)
        if any(_is_junk(part) for part in relative.parts):
            continue
        name = f"{package.name}/{relative.as_posix()}"
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            entries.append((name + "/", None))
        elif stat.S_ISREG(mode):
            entries.append((name, path))
        else:
            raise ReleaseError(f"{name} is a link or special file; a package holds only plain files and folders")
    return entries


def build_archive(package):
    """A deterministic ZIP of exactly the package folder: sorted entries, fixed times and modes, deflated."""
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, path in package_entries(package):
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            info.create_system = 3
            if path is None:
                info.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(info, b"")
            else:
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes(), compresslevel=9)
    return output.getvalue()


@dataclass(frozen=True)
class PlannedRelease:
    """One Plugin version: its release names, its built asset and whether it is already published."""

    plugin_id: str
    name: str
    version: str
    package: Path
    archive: bytes
    released: bool

    @property
    def tag(self):
        return release_tag(self.plugin_id, self.version)

    @property
    def asset(self):
        return asset_name(self.plugin_id)


def _check_manifest(package, manifest, repository):
    where = package.name
    plugin_id, version = manifest.get("id"), manifest.get("version")
    if not isinstance(plugin_id, str) or not TAG_SAFE_ID.match(plugin_id) or ".." in plugin_id \
            or plugin_id.endswith(".lock"):
        raise ReleaseError(f"{where}: id {plugin_id!r} cannot name a release tag")
    if not isinstance(version, str) or not UPDATE_VERSION.match(version):
        raise ReleaseError(f"{where}: version {version!r} is not SemVer M.m.p[-prerelease] without build metadata")
    source = manifest.get("update_source")
    if source != {"github": repository}:
        raise ReleaseError(f"{where}: update_source must be {{\"github\": \"{repository}\"}}, not {source!r}")


def _check_archive(package, entries, archive):
    seen = set()
    for name, _ in entries:
        key = unicodedata.normalize("NFC", name).casefold()
        if key in seen:
            raise ReleaseError(f"{name} differs from another path only in case or Unicode normalization")
        seen.add(key)
    if len(entries) > MAXIMUM_ENTRIES:
        raise ReleaseError(f"{package.name} has more than {MAXIMUM_ENTRIES} entries")
    if sum(path.stat().st_size for _, path in entries if path) > MAXIMUM_UNPACKED_BYTES:
        raise ReleaseError(f"{package.name} unpacks to more than {MAXIMUM_UNPACKED_BYTES // 1024 // 1024} MiB")
    if len(archive) > MAXIMUM_PACKAGE_BYTES:
        raise ReleaseError(f"{package.name} zips to more than {MAXIMUM_PACKAGE_BYTES // 1024 // 1024} MiB")


def package_contents(archive):
    """Each file in a package archive by its path inside the package folder."""
    contents = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as opened:
        for info in opened.infolist():
            parts = info.filename.rstrip("/").split("/")
            if info.is_dir() or parts[0] == "__MACOSX" or any(_is_junk(part) for part in parts):
                continue
            contents["/".join(parts[1:])] = opened.read(info)
    return contents


def _differences(published, current):
    return sorted(path for path in published.keys() | current.keys() if published.get(path) != current.get(path))


def plan(plugins, releases, repository):
    """Every package under `plugins`, built and compared with its published release, if any.

    A released version whose package changed is refused: a published version never changes.
    """
    packages = sorted(Path(plugins).glob("*.spinnetplugin"))
    built = []
    owners = {}
    for package in packages:
        manifest = json.loads((package / "manifest.json").read_text())
        _check_manifest(package, manifest, repository)
        if manifest["id"] in owners:
            raise ReleaseError(f"{package.name} and {owners[manifest['id']]} share the id {manifest['id']}")
        owners[manifest["id"]] = package.name
        entries = package_entries(package)
        archive = build_archive(package)
        _check_archive(package, entries, archive)
        built.append((manifest, package, archive))

    planned = []
    for manifest, package, archive in built:
        tag, name = release_tag(manifest["id"], manifest["version"]), asset_name(manifest["id"])
        published = releases.released_asset(tag, name)
        if published is not None:
            changed = _differences(package_contents(published), package_contents(archive))
            if changed:
                raise ReleaseError(
                    f"{tag} is already released, but {package.name} changed since: {', '.join(changed)}. "
                    f"A published version never changes; bump its version.")
        planned.append(PlannedRelease(manifest["id"], manifest.get("name", manifest["id"]), manifest["version"],
                                      package, archive, published is not None))
    return sorted(planned, key=lambda item: item.tag)


def release_notes(item):
    return (f"{item.name} {item.version} (`{item.plugin_id}`).\n\n"
            f"Spinnet offers this version as a Plugin Update to anyone who installed {item.name}. "
            f"To install it from a file, download `{item.asset}`, unzip it and open the "
            f"`{item.package.name}` folder with Spinnet.\n")


def write_assets(planned, out):
    """Writes each asset to `out` under its release asset name and returns their paths by tag."""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    paths = {}
    for item in planned:
        path = out / item.asset
        path.write_bytes(item.archive)
        paths[item.tag] = path
    return paths


def publish(planned, publisher, target, out):
    """Creates a release at `target` for every planned version not yet released."""
    pending = [item for item in planned if not item.released]
    paths = write_assets(pending, out)
    for item in pending:
        publisher.create(item.tag, paths[item.tag], f"{item.name} {item.version}", release_notes(item), target)
    return pending


# MARK: - GitHub, through the gh CLI

def _gh(*arguments, binary=False):
    result = subprocess.run(["gh", *arguments], capture_output=True, text=not binary)
    if result.returncode != 0:
        error = result.stderr if not binary else result.stderr.decode(errors="replace")
        raise ReleaseError(f"gh {' '.join(arguments)} failed: {error.strip()}")
    return result.stdout


class GitHubReleases:
    """The repository's tags and releases, read once."""

    def __init__(self, repository):
        self.repository = repository
        refs = _gh("api", "--paginate", f"repos/{repository}/git/matching-refs/tags/", "--jq", ".[].ref")
        self.tags = {line.removeprefix("refs/tags/") for line in refs.splitlines() if line}
        lines = _gh("api", "--paginate", f"repos/{repository}/releases", "--jq", ".[] | @json")
        self.releases = {release["tag_name"]: release for release in map(json.loads, filter(None, lines.splitlines()))}

    def released_asset(self, tag, name):
        release = self.releases.get(tag)
        if release is None:
            if tag in self.tags:
                raise ReleaseError(f"Tag {tag} exists without a release; publish it by hand or bump the version")
            return None
        if release.get("draft"):
            raise ReleaseError(f"The release {tag} is a draft; publish or remove it by hand")
        asset = next((asset for asset in release.get("assets", []) if asset["name"] == name), None)
        if asset is None:
            raise ReleaseError(f"The release {tag} has no asset named {name}")
        return _gh("api", "-H", "Accept: application/octet-stream",
                   f"repos/{self.repository}/releases/assets/{asset['id']}", binary=True)


class GitHubPublisher:
    def __init__(self, repository):
        self.repository = repository

    def create(self, tag, asset, title, notes, target):
        _gh("release", "create", tag, str(asset), "--repo", self.repository, "--target", target,
            "--title", title, "--notes", notes)
        print(f"Released {tag}")


class NoReleases:
    """Builds without asking GitHub: every version counts as unreleased."""

    def released_asset(self, tag, name):
        return None


# MARK: - Command line

def _report(planned):
    for item in planned:
        print(f"{'released  ' if item.released else 'unreleased'}  {item.tag}  {item.asset}")
    unreleased = sum(not item.released for item in planned)
    print(f"{unreleased} unreleased, {len(planned) - unreleased} already released")


def _clean_target(plugins):
    status = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", str(plugins)],
                            capture_output=True, text=True, check=True).stdout
    if status:
        raise ReleaseError(f"Plugins have uncommitted changes; a release is built from a commit:\n{status}")
    return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "plan", "publish"):
        command = commands.add_parser(name)
        command.add_argument("--plugins", type=Path, default=ROOT / "Plugins")
        command.add_argument("--repo", default=REPOSITORY)
        command.add_argument("--out", type=Path, required=name == "build", help="where to write the assets")
        if name == "publish":
            command.add_argument("--dry-run", action="store_true", help="only plan")
    options = parser.parse_args(arguments)
    try:
        if options.command == "build":
            planned = plan(options.plugins, NoReleases(), options.repo)
            write_assets(planned, options.out)
            print(f"Built {len(planned)} assets in {options.out}")
            return 0
        planned = plan(options.plugins, GitHubReleases(options.repo), options.repo)
        _report(planned)
        if options.command == "plan" or options.dry_run:
            if options.out:
                write_assets(planned, options.out)
            return 0
        target = _clean_target(options.plugins)
        with tempfile.TemporaryDirectory() as temporary:
            published = publish(planned, GitHubPublisher(options.repo), target, options.out or Path(temporary))
        print(f"Published {len(published)} releases at {target}")
        return 0
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
