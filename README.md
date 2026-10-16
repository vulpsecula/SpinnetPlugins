# Spinnet Plugins

The official Plugins shipped with Spinnet, distributed under MIT. Each package
under `Plugins/` is independently installable; Bundled distribution grants no
extra authority. Emoji remains a proof workload and is not shipped here.

Tests depend one way on Spinnet's public `SpinnetPluginTestKit` and real
`SpinnetPluginHelper`, pinned by full Host commit in `Package.swift`. They import
no private Host modules. On macOS with Xcode's Swift toolchain:

```sh
swift test
```

The package dependency builds the real helper. No local Host checkout, git tag,
submodule or Host-specific test harness is required. Package behaviour tests and
recorded Host answers do not establish native permissions or actual App behaviour.

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

A new proved Plugin joins individually through its onboarding issue (#94–#98
in Spinnet): copy its normally installable package under `Plugins/`, declare only
stable contracts, preserve IDs and exact upstream notices, add public kit tests
here, and update the Host lock and shipped regression coverage after review.
A candidate-only probe must stabilize before onboarding. Do not add Emoji.

See [HISTORY.md](HISTORY.md) for the preserved history and licence provenance.
