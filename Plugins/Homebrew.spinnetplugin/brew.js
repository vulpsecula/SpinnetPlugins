const entryMode = "list";
const entryCommand = "brew.open";
(() => {
  const c = spinnet.ui.components;
  const names = ["list", "outdated", "search", "info", "update", "upgrade", "install", "uninstall", "adopt", "services", "tap", "untap", "doctor", "cleanup", "autoremove", "config", "version"];
  const titles = ["List Installed Packages", "List Available Updates", "Search Packages", "Package Info", "Update Homebrew Catalog", "Upgrade Packages", "Install Package", "Uninstall Package", "Adopt an Existing App", "Services", "List or Add Taps", "Remove Tap", "Doctor", "Clean Up", "Remove Unused Dependencies", "Configuration", "Version"];
  const e = event || {}, initial = typeof input === "object" && input || {};
  const legacy = entryMode === "legacy-security" ? "Security Check is no longer provided by this command launcher. Choose a native Homebrew command below."
    : entryMode === "legacy-cache" ? "This command launcher does not cache package information. Your previous Plugin data has been retained." : "";
  const s = Object.assign({command: names.includes(entryMode) ? entryMode : "list", package: initial.package || "", kind: "both", serviceAction: "list", message: ""}, state || {});
  if (e.type === "called") Object.assign(s, {command: names.includes(entryMode) ? entryMode : "list", package: initial.package || "", message: ""});
  for (const key of ["command", "package", "kind", "serviceAction"]) if (e.values && typeof e.values[key] === "string") s[key] = e.values[key];
  if (!names.includes(s.command)) s.command = "list";
  const packageCommands = ["list", "outdated", "search", "info", "upgrade", "install", "uninstall"];
  const hasPackage = packageCommands.includes(s.command) || ["adopt", "services", "tap", "untap"].includes(s.command);
  const needsPackage = ["install", "uninstall", "search", "info", "adopt", "untap"].includes(s.command) || (s.command === "services" && s.serviceAction !== "list");
  const packageText = String(s.package || "").trim();
  const argument = {command: s.command};
  if (packageCommands.includes(s.command) && ["formula", "cask"].includes(s.kind)) argument.kind = s.kind;
  if (s.command === "services") argument.action = ["list", "start", "stop", "restart", "info"].includes(s.serviceAction) ? s.serviceAction : "list";
  if (hasPackage && packageText && (s.command !== "services" || argument.action !== "list")) argument.package = packageText;
  let problem = needsPackage && !packageText ? "Enter " + (s.command === "search" ? "search text." : s.command === "untap" ? "a tap in owner/repository form." : "a package name.") : "";
  if (argument.package && (packageText.length > 200 || /[\x00-\x1f\x7f]/.test(packageText))) problem = "Use up to 200 characters without control characters.";
  if (argument.package && s.command !== "search" && !(["tap", "untap"].includes(s.command) ? /^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*$/ : /^(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*$/).test(packageText)) problem = "Enter one package name or owner/repository/package, without shell options.";
  const argv = [s.command === "version" ? "--version" : s.command];
  if (argument.kind) argv.push("--" + argument.kind);
  if (s.command === "services") argv.push(argument.action);
  if (s.command === "adopt") argv.splice(0, argv.length, "install", "--cask", "--adopt");
  if (argument.package) argv.push("--", argument.package);
  const quote = value => /^[a-zA-Z0-9_./@+-]+$/.test(value) ? value : "'" + value.replace(/'/g, "'\\''") + "'";
  const preview = ["brew"].concat(argv).map(quote).join(" ");
  let operation;
  if (e.type === "action_chosen" && e.action === "run-terminal" && !problem) {
    operation = spinnet.apps.perform.operation({bundle_id: "com.apple.Terminal", operation: "homebrew", arguments: argument}, {id: "terminal-handoff", notify: true});
    s.message = "Opening Terminal…";
  }
  if (e.type === "operation_finished" && e.operation === "terminal-handoff") s.message = e.outcome === "succeeded"
    ? "Sent to Terminal. Output, progress and authorization are shown there."
    : "Could not open the command in Terminal" + (e.reason ? ": " + e.reason : ".");
  const content = [c.choiceField({id: "command", title: "Homebrew Command", choices: names, choiceTitles: titles, value: s.command})];
  if (packageCommands.includes(s.command)) content.push(c.choiceField({id: "kind", title: "Package Type", choices: ["both", "formula", "cask"], choiceTitles: ["Default", "Formula", "Cask App"], value: s.kind}));
  if (s.command === "services") content.push(c.choiceField({id: "serviceAction", title: "Service Action", choices: ["list", "start", "stop", "restart", "info"], value: argument.action}));
  if (hasPackage && (s.command !== "services" || argument.action !== "list")) content.push(c.textField({id: "package", title: s.command === "search" ? "Search Text" : ["tap", "untap"].includes(s.command) ? "Tap (optional for listing)" : "Package" + (needsPackage ? "" : " (optional)"), value: s.package, placeholder: ["tap", "untap"].includes(s.command) ? "owner/repository" : "e.g. wget or firefox"}));
  content.push(c.text({id: "command-preview", title: "Run in Terminal", text: preview}));
  content.push(c.text({id: "execution-help", text: "Terminal runs this command and shows Homebrew's original output. Use Terminal for input, administrator authorization and Control-C. Spinnet does not manage this as a Task.", style: {color: "secondary"}}));
  if (legacy) content.push(c.text({id: "legacy-command", text: legacy, style: {color: "secondary"}}));
  if (problem) content.push(c.text({id: "input-help", text: problem}));
  else content.push(c.actions({id: "execute", actions: [c.button({id: "run-terminal", title: "Run in Terminal"})]}));
  if (s.message) content.push(c.text({id: "handoff-status", text: s.message}));
  return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-terminal", title: "Homebrew", resizable: {minHeight: 300}, content}), {state: s, operation});
})()
