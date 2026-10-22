# Spinnet Plugins

The official Plugin packages consumed by Spinnet packaging, distributed under
MIT. Each package under `Plugins/` is independently installable; Bundled
distribution grants no extra authority. Emoji remains a proof workload and is
not shipped here.

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

The Coffee command exports five actual helper answers for a separate check
against the pinned Host's public page and operation schemas; export alone does
not validate them. The System Monitor command reports 1000 fresh native reads
with p50/p95 timings and output sizes. Its normal functional test still checks
late-answer rejection, physical-memory totals and the output-size bound.

Plugin workflow and package behaviour live here. The Host repository owns
authority checks, native rendering and the public [Documented Plugin
Interface](https://github.com/vulpsecula/Spinnet/tree/main/PluginAPI). Choose a
stable Plugin API Level supported by the pinned Host; the current Host supports
Levels 1–7. Adaptive cards, External App connections and unused-dependency Tasks
are stable from Level 3. Exact retired candidate declarations are refused.

To try a Host change together with a Plugin change, edit this package's SwiftPM
dependency locally (or use `swift package edit Spinnet --path /path/to/Spinnet`),
and point Host packaging at this checkout's packages:

```sh
SPINNET_BUNDLED_PLUGINS_DIR=/path/to/SpinnetPlugins/Plugins /path/to/Spinnet/script/build_and_run.sh --verify
```

For a normal release, commit and push Plugin changes, then update the Host's
`bundled-plugins.lock.json` repository URL and full commit SHA. Packaging fetches
that revision; it does not follow a branch or a tag. Neither repository contains
a git submodule or a git dependency on the other in the reverse direction.

For a new Bundled Plugin, add its normally installable package under `Plugins/`,
declare stable contracts, preserve IDs and exact upstream notices, and add public
kit tests here. Host lock updates and shipped regression coverage belong in the
Host repository. Bundled identity grants no extra authority. A candidate-only
probe must stabilize before onboarding; Emoji remains an external proof workload.

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
