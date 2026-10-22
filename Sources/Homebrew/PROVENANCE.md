# Homebrew Plugin provenance

The initial import, `f022673`, came from the accepted external Homebrew proof
#93 at `f6a9d91c96f12e0d23697f9802f3d29228483978` (version 1.5.0).
That import preserved the generated JavaScript and 66 public helper tests,
and changed the manifest from retired `adaptive_layout` r2 and
`homebrew_autoremove` r1 declarations to stable Plugin API Level 3.
The independent history was recovered at
`977a1907416de611238cb82ae6963ab406d1f598`; original `7fe9581` objects were
absent, so the import does not claim to recreate that history.

Subsequent repository commits changed the runtime, entrypoints and tests.
The current package uses stable Plugin API Level 7 and package browsers with
contextual actions, Host-owned Tasks and native output. The maintained source is
`src/catalog.js` and `src/homebrew.js`; `scripts/build.py` generates the nine
entry scripts listed in `scripts/entries.json`. Current public-helper coverage
is in `Tests/BundledPluginTests/HomebrewBrowserTests.swift` at the repository
root. The initial import's byte equality and test count are historical facts,
not descriptions of these maintained files.

The package's copyright and complete MIT licence remain in
`Plugins/Homebrew.spinnetplugin/LICENSE`; `NOTICE` records runtime-data
attribution. Homebrew, OSV and formulae.brew.sh data are fetched at runtime,
not redistributed with the Plugin.
