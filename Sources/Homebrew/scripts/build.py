from pathlib import Path
import json

root = Path(__file__).resolve().parent.parent
source = (root / "src/homebrew.js").read_text()
for command, title, mode in json.loads((root / "scripts/entries.json").read_text()):
    filename = "brew.js" if command == "brew.open" else command.replace(".", "-") + ".js"
    (root.parent.parent / "Plugins/Homebrew.spinnetplugin" / filename).write_text(
        f"const entryMode = {json.dumps(mode)};\nconst entryCommand = {json.dumps(command)};\n" + source
    )
