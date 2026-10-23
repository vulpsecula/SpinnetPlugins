"""Generate Homebrew entry scripts, or check their committed bytes without writing."""

import argparse
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT.parents[1] / "Plugins/Homebrew.spinnetplugin"


def generated_entries():
    source = (ROOT / "src/catalog.js").read_text() + "\n" + (ROOT / "src/homebrew.js").read_text()
    entries = json.loads((ROOT / "scripts/entries.json").read_text())
    generated = {}
    scripts_by_id = {}
    for command, _title, mode in entries:
        filename = "brew.js" if command == "brew.open" else command.replace(".", "-") + ".js"
        if command in scripts_by_id or filename in generated:
            raise ValueError(f"Duplicate entry ID or script: {command}")
        if Path(filename).name != filename or not filename.startswith("brew"):
            raise ValueError(f"Entry is outside the generated brew*.js namespace: {command}")
        scripts_by_id[command] = filename
        generated[filename] = (f"const entryMode = {json.dumps(mode)};\n" + source).encode()
    return generated, scripts_by_id


def check(generated, scripts_by_id):
    problems = []
    commands = json.loads((PACKAGE / "manifest.json").read_text())["commands"]
    manifest_scripts = {}
    for command in commands:
        if command["id"] in manifest_scripts:
            problems.append(f"Duplicate manifest Command ID: {command['id']}")
        manifest_scripts[command["id"]] = command.get("script")
    if manifest_scripts != scripts_by_id:
        problems.append("Manifest Command IDs/scripts differ from scripts/entries.json")
    for filename, expected in generated.items():
        path = PACKAGE / filename
        if not path.is_file():
            problems.append(f"Missing generated script: {filename}")
        elif path.read_bytes() != expected:
            problems.append(f"Generated script differs: {filename}")
    for path in sorted(PACKAGE.glob("brew*.js")):
        if path.name not in generated:
            problems.append(f"Retired generated script remains: {path.name}")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print(f"Homebrew: {len(generated)} generated entry scripts and manifest IDs/scripts agree")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report drift without changing any file")
    args = parser.parse_args()
    try:
        generated, scripts_by_id = generated_entries()
        if args.check:
            return check(generated, scripts_by_id)
        # This namespace contains generated entry scripts only; retired Commands
        # must leave neither a manifest entry nor an obsolete executable.
        for path in PACKAGE.glob("brew*.js"):
            if path.name not in generated:
                path.unlink()
        for filename, contents in generated.items():
            (PACKAGE / filename).write_bytes(contents)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Homebrew generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
