# Spinnet Plugins

The Official Plugin packages, distributed under MIT. Spinnet ships no Plugins:
each package under `Plugins/` is installed like any other Plugin and is published
here as its own GitHub Release, which every manifest declares as its Update
Source. Being official grants no extra authority. Emoji remains a proof workload
and is not shipped here.

Tests depend one way on Spinnet's public `SpinnetPluginTestKit` and real
`SpinnetPluginHelper`, pinned by full Host commit in `Package.swift`. They import
no private Host modules. On macOS with Xcode's Swift toolchain:

```sh
swift test
```

The package dependency builds the real helper. No local Host checkout, git tag,
submodule or Host-specific test harness is required. Package behaviour tests and
recorded Host answers do not establish native permissions or actual App behaviour.

Optional evidence and resource measurements report a skipped test unless enabled:

```sh
COFFEE_ANSWERS_DIR=/tmp/coffee-answers swift test --filter CoffeeTests.testOptInExportOfRealHelperAnswersForPublicSchemaValidation
SYSTEM_MONITOR_MEASURE=1 swift test --filter SystemMonitorTests.testOptInNativeMetricsReadCost
```

The Coffee command exports five actual helper answers. Validate that fresh export
with the locked standard JSON Schema validator:

```sh
uv run --locked script/check_coffee_answers.py --answers-dir /tmp/coffee-answers
```

By default this checks the manifest, all five answers and requested operation
inputs against the clean `.build/checkouts/Spinnet/PluginAPI` at the revision in
`Package.resolved`. Run `swift package resolve` first on a clean checkout.
For a joint change, explicitly pass `--host-plugin-api /path/to/Spinnet/PluginAPI`.
Optional `format` annotations are not asserted. Unsupported ICU `pattern`
expressions fail validation; this Python check does not establish Host acceptance.
Export alone does not validate the answers. Neither export nor validation runs
native keep-awake effects. The System Monitor command reports 1000 fresh native reads
with p50/p95 timings and output sizes. Its normal functional test still checks
late-answer rejection, physical-memory totals and the output-size bound.

Check Homebrew's nine generated entry scripts and manifest IDs/scripts without
writing files. After resolving the pinned dependency, exercise generation and
schema validation failures and their write boundaries:

```sh
uv run --no-project python Sources/Homebrew/scripts/build.py --check
uv run --no-project python -B -m unittest discover -s Tests/Tooling -v
```

Run the generator without `--check` after editing `Sources/Homebrew/`; it also
removes retired `brew*.js` entry scripts. Both tools resolve repository paths
from their own location, so they also work when invoked from another directory.
For JavaScript syntax, run `node --check` on the generated entries.
Native resource measurements remain opt-in.

Plugin workflow and package behaviour live here. The Host repository owns
authority checks, native rendering and the public [Documented Plugin
Interface](https://github.com/vulpsecula/Spinnet/tree/main/PluginAPI). Each current
package declares `"engines": {"spinnet": "^1.0.0"}` and uses the single current
catalogue, SDK and schemas. Only caret `^M.m.p` and exact `M.m.p` compatibility
ranges are supported. Legacy `api_level` and `candidate_contracts` declarations
are refused; package versions and test dependency pins remain independent.

To try a Host change together with a Plugin change, edit this package's SwiftPM
dependency locally (or use `swift package edit Spinnet --path /path/to/Spinnet`),
and install this checkout's packages into a Host built from that change:

```sh
/path/to/Spinnet/script/build_and_run.sh --install-plugins /path/to/SpinnetPlugins/Plugins --verify
```

Neither repository contains a git submodule or a git dependency on the other in
the reverse direction.

For a new Official Plugin, add its normally installable package under `Plugins/`,
declare Host compatibility and this repository as its Update Source, preserve IDs
and exact upstream notices, and add public kit tests here. Being official grants
no extra authority; additions need an implemented public contract before
onboarding. Emoji remains an external proof workload.

## Releasing

Each Plugin version is published as its own GitHub Release, under the names the
Host's [Update Source](https://github.com/vulpsecula/Spinnet/blob/main/PluginAPI/reference/update-source.md)
contract looks up:

| Part | Value |
| --- | --- |
| Tag | `<id>/v<version>`, such as `com.spinnet.bob/v1.1.0` |
| Asset | `<id>.spinnetplugin.zip`, holding exactly the package folder |

To release a Plugin, bump `version` in its `manifest.json` (SemVer `M.m.p` with an
optional `-prerelease`, never `+build` metadata), commit and push to `main`. The
[Release Plugins](.github/workflows/release.yml) workflow then publishes every
version that has no release yet, tagging the pushed commit; it can also be run by
hand from the Actions tab. A published version never changes: when a package's
contents differ from its released asset and its version was not bumped, the
workflow fails and publishes nothing. Tags and releases are never rewritten or
deleted; to withdraw a version, publish a higher one.

`script/release_plugins.py` (Python standard library, plus the `gh` CLI for
GitHub) builds each asset deterministically: sorted entries, fixed timestamps
and permissions, deflated, with every file in the package folder, licences and
notices included, and Finder junk such as `.DS_Store` left out. Before
publishing, it refuses a manifest whose id, version or `update_source` breaks the
Host's rules and an asset over the Host's size or entry bounds. Dry runs:

```sh
# Build every asset without asking GitHub.
uv run --no-project python script/release_plugins.py build --out tmp/dist
# List released and unreleased versions and compare released ones with GitHub
# (needs `gh auth login`); --out also keeps the built assets.
uv run --no-project python script/release_plugins.py plan --out tmp/dist
```

`publish` creates the missing releases from a clean checkout at `HEAD`; the
workflow runs it, so it is rarely run by hand. `swift test` includes
`ReleaseAssetTests`, which builds every asset with the script and has the Host's
own updater unpack, offer and apply each one against recorded GitHub answers.

Homebrew package changes request Host-owned Tasks; the Plugin supplies neither
shell commands nor passwords. The current Host runs native Homebrew as the user,
with system sudo/PAM authentication where needed.

Smart Jump recognises links, DOI identifiers, Bilibili AV/BV numbers, local
paths and arithmetic; other text becomes a web search. The first target in a
passage wins. Quote paths containing spaces so their boundaries are explicit.
Downloads open in the default browser. In the Library's Plugin Settings,
edit the search engines row by row, each a name and an https URL with
`{query}`; the first is the default (Google initially). Arithmetic, or running
with no selection, opens a view whose field previews its target while typing.
Copying a result and opening a local path each require their own grant.

See [HISTORY.md](HISTORY.md) for the preserved history and licence provenance.
