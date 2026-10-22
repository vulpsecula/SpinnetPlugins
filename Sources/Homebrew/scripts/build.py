from pathlib import Path
import json

root = Path(__file__).resolve().parent.parent
source = (root / "src/catalog.js").read_text() + "\n" + (root / "src/homebrew.js").read_text()
entries = json.loads((root / "scripts/entries.json").read_text())
filenames = {"brew.js" if command == "brew.open" else command.replace(".", "-") + ".js"
             for command, _, _ in entries}
# This namespace contains generated entry scripts only; retired Commands must
# leave neither a manifest entry nor an obsolete executable in the package.
for path in (root.parent.parent / "Plugins/Homebrew.spinnetplugin").glob("brew*.js"):
    if path.name not in filenames:
        path.unlink()
for command, title, mode in entries:
    filename = "brew.js" if command == "brew.open" else command.replace(".", "-") + ".js"
    (root.parent.parent / "Plugins/Homebrew.spinnetplugin" / filename).write_text(
        f"const entryMode = {json.dumps(mode)};\n" + source
    )
