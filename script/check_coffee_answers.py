# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema==4.26.0", "referencing==0.37.0"]
# ///
"""Validate five exported real Coffee helper answers against a fixed Host API."""

import argparse
from functools import cache
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012


ROOT = Path(__file__).resolve().parents[1]
COMMANDS = ("coffee.open", "coffee.manual", "coffee.timed", "coffee.app", "coffee.activities")


def pinned_plugin_api():
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    pin = next(pin for pin in pins if pin["identity"].lower() == "spinnet")
    revision = pin["state"]["revision"]
    checkout = ROOT / ".build/checkouts/Spinnet"
    actual = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != revision:
        raise ValueError(f"Host checkout {actual} differs from Package.resolved {revision}; resolve the pinned dependency first")
    # A local edited checkout is not evidence for the fixed revision.
    if subprocess.check_output(
        ["git", "-C", str(checkout), "status", "--porcelain", "--", "PluginAPI"], text=True
    ).strip():
        raise ValueError("Pinned Host PluginAPI has local changes; use a clean dependency or explicit --host-plugin-api")
    return checkout / "PluginAPI", revision


def validate_answers(answers, public):
    @cache
    def retrieve(uri):
        parsed = urlparse(uri)
        if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
            raise ValueError(f"Only local public-schema references are supported: {uri}")
        path = Path(unquote(parsed.path)).resolve()
        if not path.is_relative_to(public):
            raise ValueError(f"Schema reference leaves PluginAPI: {uri}")
        return Resource.from_contents(json.loads(path.read_text()), default_specification=DRAFT202012)

    registry = Registry(retrieve=retrieve)
    operations = {entry["id"]: entry for entry in json.loads((public / "catalogue.json").read_text())["operations"]}
    checks = 0

    def validate(value, reference):
        nonlocal checks
        Draft202012Validator({"$ref": reference}, registry=registry).validate(value)
        checks += 1

    validate(json.loads((ROOT / "Plugins/KeepAwake.spinnetplugin/manifest.json").read_text()),
             (public / "schemas/manifest.schema.json").as_uri())
    for command in COMMANDS:
        path = answers / f"{command}.json"
        answer = json.loads(path.read_text())
        try:
            validate(answer, (public / "schemas/pages.schema.json").as_uri() + "#/$defs/answer")
            if isinstance(answer, dict) and "operation" in answer:
                operation = answer["operation"]
                definition = operations[operation["perform"]]["input"]
                validate(operation["input"], public.as_uri() + "/" + definition)
        except Exception as error:
            raise ValueError(f"{path.name}: {error}") from error
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--answers-dir", required=True, type=Path,
                        help="directory freshly exported by CoffeeTests.testOptInExportOfRealHelperAnswersForPublicSchemaValidation")
    parser.add_argument("--host-plugin-api", type=Path,
                        help="explicit Host PluginAPI directory; default is the clean checkout at Package.resolved's revision")
    args = parser.parse_args()
    try:
        if args.host_plugin_api:
            public, source = args.host_plugin_api.resolve(), "explicit API path"
        else:
            public, source = pinned_plugin_api()
        count = validate_answers(args.answers_dir.resolve(), public.resolve())
        print(f"Coffee: manifest + five exported helper answers + requested operation inputs pass {count} schema checks ({source}; {public})")
        return 0
    except Exception as error:
        print(f"Coffee schema check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
