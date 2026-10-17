const entryMode = "vulnerabilities";
const entryCommand = "brew.vulnerabilities";
(() => {
  const c = spinnet.ui.components;
  // Collection positions change after refresh, filtering and sorting. IDs
  // follow the semantic entity; the snapshot text also guards a hash collision.
  const entityID = identity => {
    const seeds = [2166136261, 2246822519, 3266489917, 668265263];
    return "entity_" + seeds.map(seed => {
      let hash = seed;
      for (let i = 0; i < identity.length; i++) hash = Math.imul(hash ^ identity.charCodeAt(i), 16777619);
      return (hash >>> 0).toString(16).padStart(8, "0");
    }).join("");
  };
  const packageID = p => entityID(JSON.stringify(["package", p.kind, p.name]));
  const managementText = p => String(p.name || p.text || "Finding");
  const managementTitle = p => managementText(p).split(/\r?\n/).map(line => line.trim()).find(Boolean)?.slice(0, 200) || "Finding";
  const managementID = p => entityID(JSON.stringify(["management", s.mode, p.security_skipped ? "skipped" : p.identity || p.bundle_id || "", managementText(p)]));
  const securityRecords = report => (report.findings || []).concat((report.skipped || []).map(p => Object.assign({}, p, {security_skipped: true})));
  const securityGroup = p => p.security_skipped ? "skipped" : (p.open_count || p.unknown_count || (p.advisories || []).some(a => a.status !== "patched")) ? "review" : "patched";
  const skipReason = p => ({installed_source_unavailable_or_unsupported: "The installed source version could not be identified. OSV was not queried for this package.", unsupported_upstream: "The installed package has no supported upstream Git repository."})[p.reason] || p.reason || "The installed source could not be checked.";
  const findManagement = (records, item) => records.find(p => managementID(p) === item.id && managementText(p) === item.text);
  const findPackage = (packages, item) => packages.find(p => packageID(p) === item.id && p.name === item.text);

  if (entryCommand === "brew.services-menu" && (!event || !event.type || event.type === "called")) return spinnet.ui.request(spinnet.tools.showServices.operation({tool: "homebrew", presentation: "menu"}));
  const rawGet = key => spinnet.storage.get(key);
  const readCache = key => {
    if (key === "management-doctor") key += "-v2";
    const header = rawGet(key);
    if (!header || !header.cacheParts) return header;
    const value = Object.assign({}, header); delete value.cacheParts; delete value.cacheField;
    value[header.cacheField] = [];
    for (let part = 0; part < header.cacheParts; part++) value[header.cacheField].push(...(rawGet(key + "-part-" + part) || []));
    return value;
  };
  const writeCache = ({key, value}) => {
    if (key === "management-doctor") key += "-v2";
    const prior = rawGet(key);
    const field = ["packages", "services", "taps", "findings", "applications", "previewLines", "rankings"].find(name => Array.isArray(value[name]));
    if (!field) return spinnet.storage.set({key, value});
    const records = value[field], parts = Math.ceil(records.length / 20);
    for (let part = 0; part < parts; part++) spinnet.storage.set({key: key + "-part-" + part, value: records.slice(part * 20, (part + 1) * 20)});
    for (let part = parts; part < ((prior && prior.cacheParts) || 0); part++) spinnet.storage.remove(key + "-part-" + part);
    const header = Object.assign({}, value, {cacheField: field, cacheParts: parts}); delete header[field];
    // Empty arrays need no chunks, but retain their collection field.
    if (!parts) header[field] = [];
    return spinnet.storage.set({key, value: header});
  };
  // Reports share the Plugin Storage quota with other features. Retain at
  // most one million JSON characters (at most 4 MiB in UTF-8), in small
  // append-only chunks. Commit the header last so a failed write keeps the
  // previous complete batches readable and retryable.
  const appendSecurityReport = (metadata, records) => {
    const key = "management-vulnerabilities", prior = rawGet(key) || {};
    let characters = prior.retainedCharacters || 0, count = prior.retainedCount || 0;
    let omitted = prior.omitted || 0, chunk = [], length = 2;
    const parts = [], first = prior.cacheParts || 0;
    for (const record of records) {
      const size = JSON.stringify(record).length + 1;
      if (size > 60000 || characters + size > 1000000 || count >= 2000) { omitted++; continue; }
      if (length + size > 60000 && chunk.length) { parts.push(chunk); chunk = []; length = 2; }
      chunk.push(record); length += size; characters += size; count++;
    }
    if (chunk.length) parts.push(chunk);
    let written = 0;
    try {
      for (const part of parts) { spinnet.storage.set({key: key + "-part-" + (first + written), value: part}); written++; }
      const header = Object.assign({}, metadata, {cacheField: "findings", cacheParts: first + written, retainedCharacters: characters, retainedCount: count, omitted, truncated: !!metadata.truncated || omitted > 0});
      if (!header.cacheParts) header.findings = [];
      spinnet.storage.set({key, value: header});
    } catch (error) {
      for (let part = 0; part < written; part++) spinnet.storage.remove(key + "-part-" + (first + part));
      throw error;
    }
  };
  const dropCache = key => {
    const header = rawGet(key);
    for (let part = 0; part < ((header && header.cacheParts) || 0); part++) spinnet.storage.remove(key + "-part-" + part);
    spinnet.storage.remove(key);
  };
  const s = Object.assign({mode: typeof entryMode === "string" ? entryMode : "installed", kind: "both", query: "", greedy: "off", packages: [], message: "", loading: true}, state || {});
  const pendingUpdate = rawGet("catalog-update");
  if (pendingUpdate && !s.catalogUpdateWaiting) { s.catalogUpdateWaiting = true; s.catalogUpdateBaseline = pendingUpdate.baseline || []; }
  const watching = sources => {
    const list = (sources || []).slice();
    if (!list.some(source => source.id === "activities")) list.push(spinnet.activities.list.source("activities", {every: 1, deliver: true}));
    return list.length ? list : undefined;
  };
  const e = event || {};
  if (entryCommand === "brew.open" && !e.type && !state) s.mode = "home";
  s.refresh = s.refresh || 0;
  if (e.type === "action_chosen" && e.action === "refresh") {
    s.refresh += 1; s.loading = true; s.message = ""; s.manageMessage = "";
    s.manageDetail = null; s.doctorRepairs = null; s.adoption = null; s.adoptionRequest = null; s.adoptionMessage = ""; s.advisory = null; s.advisoryID = null;
  }
  const sourceID = id => s.refresh ? id + "-" + s.refresh : id;
  const sourceIs = id => e.source === (id === "manage" && s.mode === "vulnerabilities" && s.securitySource ? s.securitySource : sourceID(id));
  if (e.type === "called") { s.detail = null; s.manageDetail = null; s.progress = false; s.previewPage = false; s.packageOptions = false; s.awaitingTask = false; s.pendingTaskBaseline = null; }
  if (typeof entryCommand === "string" && entryCommand === "brew.clear-cache" && (!e.type || e.type === "called")) {
    spinnet.storage.clear(); s.mode = "cleanup"; s.packages = []; s.manageResult = null;
    s.manageMessage = "Plugin Cache Cleared";
  }
  const modes = ["installed", "outdated", "search", "services", "taps", "vulnerabilities", "doctor", "adopt", "cleanup", "autoremove", "activity"];
  const modeTitles = ["Installed", "Updates", "Find Packages", "Services", "Taps", "Security Check", "Doctor", "Adopt Apps", "Clean Up", "Remove Unused Dependencies", "Activity"];
  const activeTask = () => (s.tasks || []).find(task => task.kind === "task" && !task.result && task.status !== "ended");
  const homeNavigation = () => {
    const task = activeTask();
    return c.column({id: "navigation-and-task", content: [
      c.actions({id: "home-navigation", actions: [c.button({id: "home", title: "Homebrew Home"}),
        c.button({id: "go-installed", title: "Installed"}), c.button({id: "go-outdated", title: "Updates"}),
        c.button({id: "go-search", title: "Find Packages"})].concat(s.progress ? [] : [c.button({id: "task-details", title: "Tasks and Logs"})])}),
      ...(task && !s.progress ? [c.text({id: "active-task-summary", text: task.name + " · " + (task.stage || "Running") + " · " + Math.floor(task.elapsed_seconds || 0) + "s", style: {color: "accent"}})] : [])
    ]});
  };
  // Homebrew reports download bytes (and curl sometimes reports a percent).
  // These bars describe individual downloads, never the whole upgrade.
  const taskDownloads = task => {
    if (task.result || ["installing", "linking", "finishing"].includes(task.stage)) return [];
    const units = {B: 1, KB: 1000, MB: 1e6, GB: 1e9, TB: 1e12, KIB: 1024, MIB: 1048576, GIB: 1073741824, TIB: 1099511627776};
    return (task.log || []).slice(-20).map(line => {
      const bytes = line.match(/^(.*?)\s+Downloading\s+([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)\/\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)\s*$/i);
      if (bytes) {
        const received = Number(bytes[2]) * units[bytes[3].toUpperCase()], total = Number(bytes[4]) * units[bytes[5].toUpperCase()];
        if (Number.isFinite(received) && Number.isFinite(total) && total > 0 && received <= total)
          return {title: bytes[1].replace(/[# ]+$/, "").trim() || "Download", value: received / total, status: "Download · " + bytes[2] + bytes[3] + " / " + bytes[4] + bytes[5]};
      }
      const percent = line.match(/^\s*#+[# ]*\s+([0-9]+(?:\.[0-9]+)?)%\s*$/);
      if (percent && Number(percent[1]) <= 100) return {title: "Download", value: Number(percent[1]) / 100, status: "Download · " + percent[1] + "%"};
      return null;
    }).filter(Boolean).slice(-8);
  };
  const changeMode = mode => {
    if (s.mode === mode) return;
    const defaults = {filter: "", query: "", kind: "both", greedy: "off", hideDependencies: "off", sort: "catalogue", filterOptions: false, start: 0, count: 80};
    s.browseState = s.browseState || {};
    if (["installed", "outdated", "search"].includes(s.mode)) {
      const held = {};
      for (const key of Object.keys(defaults)) if (s[key] !== undefined) held[key] = s[key];
      s.browseState[s.mode] = held;
    }
    if (["installed", "outdated", "search"].includes(mode)) Object.assign(s, defaults, s.browseState[mode] || {});
    if (s.mode === "vulnerabilities" && s.securityStatus === "running") s.securityStatus = "cancelled";
    s.mode = mode; s.manageDetail = null; s.doctorRepairs = null; s.manageResult = null; s.manageMessage = "";
  };
  if (e.values) {
    if (typeof e.values.caskName === "string" && e.values.caskName !== s.caskName) { s.adoption = null; s.adoptionRequest = null; s.adoptionMessage = ""; s.adoptionRefresh = (s.adoptionRefresh || 0) + 1; }
    for (const key of ["kind", "query", "greedy", "filter", "hideDependencies", "tapName", "caskName", "pruneDays", "zap", "language", "adoptionFilter", "sort"]) if (typeof e.values[key] === "string") s[key] = e.values[key];
    if (modes.includes(e.values.browse)) changeMode(e.values.browse);
  }
  if (e.type === "called") changeMode(entryCommand === "brew.open" ? "home" : entryMode);
  if (e.type === "action_chosen" && e.action === "home") {
    changeMode("home"); s.detail = null; s.manageDetail = null; s.progress = false; s.previewPage = false; s.packageOptions = false;
  }
  if ((e.type === "item_action" && e.action === "navigate" && modes.includes(e.item.id)) || (e.type === "action_chosen" && e.action.startsWith("go-") && modes.includes(e.action.slice(3)))) {
    changeMode(e.type === "item_action" ? e.item.id : e.action.slice(3)); s.detail = null; s.manageDetail = null; s.manageResult = null;
    s.progress = false; s.previewPage = false; s.packageOptions = false;
  }
  let operation;
  const startTask = (input, options) => {
    s.pendingTaskBaseline = (spinnet.activities.list() || []).filter(task => task.kind === "task").map(task => task.id);
    return spinnet.tools.startTask.operation(input, options);
  };
  // Invocation state may encode object keys in a different order. Bind the
  // cached preview to its semantic typed request, not JSON member order.
  const previewRequest = input => JSON.stringify(Object.keys(input || {}).sort().map(key => [key, input[key]]));
  const beginPreview = input => {
    s.previewInput = input; s.previewPage = true; s.previewLoaded = false; s.previewMessage = "";
    s.previewLine = null; s.previewStart = 0;
    s.previewRefresh = (s.previewRefresh || 0) + 1;
    s.previewSourceID = s.previewRefresh > 1 ? "preview-" + s.previewRefresh : "preview";
    writeCache({key: "preview-result", value: {previewLines: [], sourceID: s.previewSourceID, request: previewRequest(input)}});
  };
  s.selectedUpgrades = s.selectedUpgrades || {formula: [], cask: []};
  if (e.type === "item_action" && e.action === "queue-upgrade") {
    const held = readCache("packages-" + s.mode);
    const pkg = findPackage((held && held.packages) || s.packages, e.item);
    if (!pkg) s.message = "This package disappeared after refresh. Choose a current package.";
    if (pkg && pkg.outdated && !pkg.pinned) {
      const selected = s.selectedUpgrades[pkg.kind];
      const at = selected.indexOf(pkg.name);
      if (at >= 0) selected.splice(at, 1); else if (selected.length < 50) selected.push(pkg.name);
    }
  }
  if (e.type === "action_chosen" && e.action === "upgrade-all") operation = startTask(Object.assign({tool: "homebrew", operation: "upgradeAll", greedy: s.greedy === "on"}, s.kind !== "both" ? {kind: s.kind} : {}), {id: "upgrade-all", notify: true});
  if (e.type === "action_chosen" && e.action.startsWith("upgrade-selected-")) {
    const kind = e.action.slice(17), names = s.selectedUpgrades[kind];
    if (names && names.length) operation = startTask(Object.assign({tool: "homebrew", operation: "upgradeSelected", kind, names}, kind === "cask" ? {greedy: s.greedy === "on"} : {}), {id: "selected-" + kind, notify: true});
  }
  if (e.type === "action_chosen" && ["install", "upgrade", "uninstall", "pin", "unpin"].includes(e.action) && s.detail) {
    operation = startTask(Object.assign({tool: "homebrew", operation: e.action, kind: s.detail.kind, name: s.detail.name}, e.action === "uninstall" && s.detail.kind === "cask" && s.zap === "on" ? {zap: true} : {}), {id: e.action, notify: true});
  }
  if (e.type === "action_chosen" && e.action === "change-language" && s.detail && s.detail.kind === "cask" && (s.detail.languages || []).includes(s.language || s.detail.selected_language || s.detail.languages[0])) operation = startTask({tool: "homebrew", operation: "changeLanguage", kind: "cask", name: s.detail.name, language: s.language || s.detail.selected_language || s.detail.languages[0]}, {notify: true});
  if (e.type === "operation_finished" && e.perform === "tools.startTask") {
    if (e.outcome === "succeeded") { s.progress = true; s.taskID = null; s.awaitingTask = true; if (["review-link", "review-unlink"].includes(e.operation)) s.previewPage = false; }
    else { s.awaitingTask = false; s.pendingTaskBaseline = null; s.detailMessage = "Task " + e.outcome + (e.reason ? ": " + e.reason : ""); if (s.mode === "autoremove") s.autoremoveTaskMessage = s.detailMessage; if (e.operation === "catalog-update") { s.catalogUpdateWaiting = false; spinnet.storage.remove("catalog-update"); } }
  }
  if (e.type === "action_chosen" && e.action === "browse") { s.progress = false; s.taskID = null; }
  if (e.type === "action_chosen" && e.action === "task-details") { s.progress = true; s.taskID = (activeTask() || {}).id || null; }
  if (e.type === "item_action" && e.action === "show-task" && (s.tasks || []).some(task => task.id === e.item.id && task.name === e.item.text)) s.taskID = e.item.id;
  if (e.type === "action_chosen" && e.action === "tasks-back") s.taskID = null;
  if (e.type === "load_range" && e.collection === "tasks") { s.taskStart = e.start; s.taskCount = Math.min(e.count, 80); }
  if (e.type === "action_chosen" && e.action.startsWith("cancel-")) operation = spinnet.activities.stop.operation({id: e.action.slice(7)}, {notify: true});
  if (e.type === "source_delivered" && e.source === "activities") {
    if (e.failure) s.taskMessage = e.failure.message;
    else { s.tasks = e.result || []; s.tasksLoaded = true; s.taskMessage = ""; }
    if (!e.failure && s.awaitingTask) {
      const admitted = s.tasks.find(task => task.kind === "task" && !(s.pendingTaskBaseline || []).includes(task.id));
      if (admitted) { s.taskID = admitted.id; s.awaitingTask = false; s.pendingTaskBaseline = null; }
    }
    if (!e.failure && s.catalogUpdateWaiting) {
      const task = s.tasks.find(t => t.kind === "task" && t.operation === "update" && !(s.catalogUpdateBaseline || []).includes(t.id));
      if (task && task.result) {
        s.catalogUpdateWaiting = false; spinnet.storage.remove("catalog-update");
        for (const key of ["packages-installed", "packages-outdated", "packages-search", "preview-result", "tap-packages", "popularity-formula", "popularity-cask"].concat(modes.map(mode => "management-" + mode))) dropCache(key);
        s.packages = []; s.manageResult = null; s.manageDetail = null; s.definition = null; s.toolVersion = null; s.toolFeatures = null;
        s.refresh += 1; s.detailRefresh = (s.detailRefresh || 0) + 1; s.detailLoaded = false;
        if (s.detail) s.detail = {name: s.detail.name, kind: s.detail.kind};
        s.detailMessage = "Catalog update " + task.result.outcome + ". Reloading current package metadata.";
        s.analyticsInput = null; s.analytics = null; s.previewInput = null; s.preview = null; s.previewPage = false;
      }
    }
  }
  if (e.type === "action_chosen" && e.action === "check-updates") {
    s.catalogUpdateBaseline = (spinnet.activities.list() || []).map(task => task.id);
    s.catalogUpdateWaiting = true;
    spinnet.storage.set({key: "catalog-update", value: {baseline: s.catalogUpdateBaseline}});
    s.detailMessage = "Check for Updates changes Homebrew itself, all taps and package catalogs after Host Confirmation.";
    operation = startTask({tool: "homebrew", operation: "update"}, {id: "catalog-update", notify: true});
  }
  if (e.type === "operation_finished" && e.view_closed) return {};
  if (s.mode === "home" && !s.detail && !s.progress) {
    const destinations = [
      ["installed", "Installed Packages", "Browse installed tools and Apps, and manage a package.", "shippingbox"],
      ["search", "Find Packages", "Search for a tool or App to install.", "magnifyingglass"],
      ["outdated", "Available Updates", "Review and choose which packages to upgrade.", "arrow.down.circle"],
      ["services", "Services", "View and control background services.", "gearshape.2"],
      ["taps", "Package Sources", "Manage taps and which sources you trust.", "externaldrive"],
      ["vulnerabilities", "Security Check", "Check installed tools for known vulnerabilities.", "checkmark.shield"],
      ["doctor", "Doctor", "Check Homebrew health and review suggested repairs.", "stethoscope"],
      ["adopt", "Adopt Existing Apps", "Review Apps you installed outside Homebrew.", "app.badge"],
      ["cleanup", "Clean Up", "Remove old downloads and package versions, or clear this Plugin's cache.", "trash"],
      ["autoremove", "Remove Unused Dependencies", "Preview and remove tools installed only as dependencies that are no longer needed.", "shippingbox.and.arrow.backward"],
      ["activity", "Tasks and Logs", "Follow running work and review previous results.", "clock"]
    ];
    return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-home", title: "Homebrew", resizable: {minHeight: 360}, content: [
      homeNavigation(),
      c.text({id: "intro", text: "What would you like to do?", style: {fontSize: 18, fontWeight: "semibold"}}),
      c.actions({id: "catalog-controls", actions: [c.button({id: "check-updates", title: "Update Homebrew Catalog…"})]}),
      c.text({id: "navigation-help", text: "Open a section with Return or a double-click. Changes are reviewed before they run.", style: {color: "secondary"}}),
      c.list({id: "destinations", total: destinations.length, start: 0, sections: [c.section({id: "packages", title: "Packages", count: 3}), c.section({id: "manage", title: "Manage Homebrew", count: 7}), c.section({id: "tasks", title: "Activity", count: 1})],
        items: destinations.map(([id, title, subtitle, symbol]) => c.item({id, title, text: title, subtitle, icon: {symbol}})),
        actions: [c.itemAction({id: "navigate", title: "Open", default: true})]})
    ], sources: watching([])}), {state: s, operation});
  }
  if (e.type === "action_chosen" && (e.action === "preview-upgrade-all" || e.action.startsWith("preview-selected-"))) {
    const kind = e.action.slice(17), names = s.selectedUpgrades[kind];
    if (e.action === "preview-upgrade-all" || (names && names.length)) {
      beginPreview(e.action === "preview-upgrade-all" ? Object.assign({tool: "homebrew", operation: "previewUpgradeAll", greedy: s.greedy === "on"}, s.kind !== "both" ? {kind: s.kind} : {}) : Object.assign({tool: "homebrew", operation: "previewUpgrade", kind, names}, kind === "cask" ? {greedy: s.greedy === "on"} : {}));
    }
  }
  if (e.type === "action_chosen" && ["previewInstall", "previewUpgrade", "link", "unlink"].includes(e.action) && s.detail) {
    const input = {tool: "homebrew", operation: e.action === "link" ? "previewLink" : e.action === "unlink" ? "previewUnlink" : e.action, kind: s.detail.kind, names: [s.detail.name]};
    if (e.action === "previewUpgrade" && s.detail.kind === "cask") input.greedy = s.greedy === "on";
    beginPreview(input);
  }
  if (e.type === "action_chosen" && e.action === "preview-back") { s.previewPage = false; s.previewLine = null; }
  if (s.mode === "activity") s.progress = true;
  if (s.progress) {
    const content = [homeNavigation()];
    if (s.taskMessage) content.push(c.text({id: "task-error", text: "Could not refresh tasks: " + s.taskMessage + ((s.tasks || []).length ? " Showing the last known status and logs." : ""), style: {color: "orange"}}));
    const tasks = (s.tasks || []).filter(t => t.kind === "task");
    const task = tasks.find(t => t.id === s.taskID);
    if (task) {
      content.push(c.actions({id: "tasks-navigation", actions: [c.button({id: "tasks-back", title: "Back to Tasks"})]}));
      const outcome = task.result && task.result.outcome;
      content.push(c.progress({id: "progress-" + task.id, title: task.name, status: task.stage + " · " + Math.floor(task.elapsed_seconds || 0) + "s" + (outcome ? " · " + outcome : ""), state: outcome === "completed" ? "succeeded" : outcome === "stopped" ? "cancelled" : outcome ? "failed" : task.status === "stopping" ? "cancelling" : "running", cancel: task.status === "running" ? {id: "cancel-" + task.id, title: "Stop"} : undefined}));
      const downloads = taskDownloads(task);
      for (let index = 0; index < downloads.length; index++) content.push(c.progress(Object.assign({id: "download-progress-" + index, state: task.status === "stopping" ? "cancelling" : "running"}, downloads[index])));
      if (downloads.length) content.push(c.text({id: "download-scope", text: "Download progress is shown per file. Installation continues after downloading.", style: {color: "secondary"}}));
      content.push(c.text({id: "log-" + task.id, title: "Task Log", text: (task.log || []).join("\n") || (outcome ? "No log output was recorded." : "Waiting for Homebrew output…")}));
      content.push(c.text({id: "task-help", text: outcome ? "This task has ended. Viewing its result or log does not run it again." : "Stopping attempts to end this task. It does not undo changes already made.", style: {color: "secondary"}}));
    } else if (s.awaitingTask) {
      content.push(c.progress({id: "pending-task-progress", title: "Starting Homebrew Task", status: "Waiting for task status…", state: "running"}));
    } else {
      content.push(c.text({id: "task-help", text: "Open a task to see its result, progress and log. Running tasks continue when this window closes.", style: {color: "secondary"}}));
      const start = Math.min(s.taskStart || 0, Math.max(0, tasks.length - 1));
      content.push(c.list({id: "tasks", total: tasks.length, start, items: tasks.slice(start, start + (s.taskCount || 80)).map(task => c.item({id: task.id, title: task.name, text: task.name,
        subtitle: [task.result ? task.result.outcome : task.status === "stopping" ? "Stopping…" : "Running", task.stage, Math.floor(task.elapsed_seconds || 0) + "s"].filter(Boolean).join(" · ")})),
        emptyText: s.taskMessage ? "Task status is unavailable. Retrying while this page is open." : !s.tasksLoaded ? "Loading tasks…" : "No Homebrew tasks yet. Start an operation from a package or management page.", actions: [c.itemAction({id: "show-task", title: "Show Task Details", default: true})]}));
    }
    if (s.mode !== "activity") content.push(c.actions({id: "navigation", actions: [c.button({id: "browse", title: "Back to " + (s.detail ? s.detail.title || s.detail.name : modeTitles[modes.indexOf(s.mode)] || "Homebrew" )})]}));
    return spinnet.ui.showPage(spinnet.ui.page({id: task ? "homebrew-task-" + task.id : "homebrew-progress", title: task ? task.name : "Tasks and Logs", resizable: {minHeight: 320}, content, sources: [spinnet.activities.list.source("activities", {every: 1, deliver: true})]}), {state: s, operation});
  }
  if (s.previewPage) {
    const previewSourceID = s.previewSourceID || "preview";
    const isLink = ["previewLink", "previewUnlink"].includes((s.previewInput || {}).operation);
    if (e.type === "source_delivered" && e.source === previewSourceID) {
      s.previewLoaded = true;
      if (e.failure) {
        s.previewMessage = e.failure.message;
        writeCache({key: "preview-result", value: {previewLines: [], sourceID: previewSourceID, request: previewRequest(s.previewInput)}});
      }
      else {
        const result = e.result || {}, previewLines = [];
        const append = (title, text) => { const value = String(text || ""); for (let start = 0; start < value.length; start += 4000) previewLines.push({title: String(title).slice(0, 256), text: value.slice(start, start + 4000)}); };
        const changes = Array.isArray(result.changes) ? result.changes : [];
        if (isLink) {
          const titles = {link: "Link", unlink: "Remove", mkdir: "Create Directory", rmdir: "Remove Empty Directory", update_info_index: "Update Info Index"};
          for (const change of changes) append(titles[change.action] || "Change", change.path + (change.source ? "\nNew source: " + change.source : ""));
        } else {
          for (const stage of result.stages || []) append(stage.title || "Homebrew", (stage.lines || []).join("\n"));
          if (!(result.stages || []).length) append("Homebrew Output", result.stdout);
        }
        append("Warnings", (result.warnings || []).join("\n"));
        append("Diagnostics", result.stderr);
        const matching = result.kind === s.previewInput.kind && result.package && result.package.kind === result.kind && result.package.name === result.name;
        const validChanges = changes.length > 0 && changes.length <= 2000 && changes.every(change => typeof change.path === "string" && ["link", "unlink", "mkdir", "rmdir", "update_info_index"].includes(change.action) && (change.action !== "link" || typeof change.source === "string"));
        const ready = isLink && matching && result.available === true && result.succeeded === true && result.complete === true && result.no_op === false && result.truncated === false && validChanges && /^[a-f0-9]{64}$/.test(result.paths_fingerprint || "");
        writeCache({key: "preview-result", value: {previewLines, summary: result.summary || result.reason || "Preview complete", available: result.available, succeeded: result.succeeded, complete: result.complete, no_op: result.no_op, exit_status: result.exit_status, dry_run: result.dry_run,
          sourceID: previewSourceID, request: previewRequest(s.previewInput), linkTask: ready ? {tool: "homebrew", operation: s.previewInput.operation === "previewLink" ? "link" : "unlink", kind: result.kind, name: result.name} : null}});
      }
    }
    const stored = readCache("preview-result");
    const result = stored && (stored.sourceID === undefined || stored.sourceID === previewSourceID) && (stored.request === undefined || stored.request === previewRequest(s.previewInput)) ? stored : {previewLines: []};
    if (e.type === "action_chosen" && ["review-link", "review-unlink"].includes(e.action) && s.previewLoaded && result.linkTask && e.action === "review-" + result.linkTask.operation) operation = startTask(result.linkTask, {id: e.action, notify: true});
    if (e.type === "load_range" && e.collection === "preview-lines") { s.previewStart = e.start; s.previewCount = Math.min(e.count, 40); }
    if (e.type === "item_action" && e.action === "preview-line") s.previewLine = Number(e.item.id);
    if (e.type === "action_chosen" && e.action === "preview-lines-back") s.previewLine = null;
    const content = [
      homeNavigation(),
      c.text({id: "preview-summary", text: s.previewMessage || (s.previewLoaded ? result.summary || "Awaiting a current preview." : "Running Homebrew's controlled dry-run…")}),
      c.text({id: "preview-status", text: !s.previewLoaded ? "No Task has started." : result.available === false ? "Preview unavailable for this Homebrew version." : result.succeeded === false || (isLink && result.complete !== true) ? "Homebrew refused the dry-run. Exit status: " + (result.exit_status === undefined ? "unknown" : result.exit_status) : result.no_op === true ? "No links would change. No Task is needed." : "Homebrew dry-run complete. No Task has started."})
    ];
    const lines = result.previewLines || [];
    if (s.previewLine !== null && s.previewLine !== undefined && lines[s.previewLine]) {
      const selected = lines[s.previewLine];
      content.push(c.text({id: "preview-line-text", title: selected.title, text: selected.text}), c.actions({id: "preview-line-navigation", actions: [c.button({id: "preview-lines-back", title: "Back to Preview Steps"})]}));
    } else {
      const start = Math.min(s.previewStart || 0, Math.max(0, lines.length - 1));
      content.push(c.list({id: "preview-lines", total: lines.length, start, items: lines.slice(start, start + (s.previewCount || 40)).map((line, index) => c.item({id: String(start + index), title: line.text.split("\n")[0].slice(0, 256) || line.title, subtitle: line.title, text: line.text})), emptyText: s.previewLoaded ? "No Homebrew output" : "Waiting for Homebrew…", actions: [c.itemAction({id: "preview-line", title: "Show Full Step", default: true})]}));
    }
    content.push(c.actions({id: "preview-navigation", actions: [c.button({id: "preview-back", title: s.detail ? "Back to Package" : "Back to Updates"})]}));
    if (isLink && s.previewLoaded && result.linkTask) content.push(c.actions({id: "preview-task", actions: [c.button({id: "review-" + result.linkTask.operation, title: "Review " + (result.linkTask.operation === "link" ? "Link" : "Unlink") + " Task"})]}));
    return spinnet.ui.showPage(spinnet.ui.page({id: s.previewLine !== null && s.previewLine !== undefined ? "homebrew-preview-step" : "homebrew-preview", title: "Homebrew Preview", resizable: {minHeight: 320}, content, sources: watching([spinnet.tools.read.source(previewSourceID, s.previewInput, {deliver: true})])}), {operation, state: s});
  }
  if (e.type === "action_chosen" && e.action === "manage-back") s.manageDetail = null;
  if (e.type === "item_action" && e.action === "tap-package") { const cache = readCache("tap-packages"); s.detail = findPackage((cache && cache.packages) || s.tapPackages || [], e.item); s.detailLoaded = false; s.previewInput = null; s.preview = null; s.analyticsInput = null; s.analytics = null; }
  const qualified = s.mode === "search" && /^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9+_.@-]*$/.test(s.query || "") && s.query.length <= 160;
  if (qualified && !s.detail) {
    const parts = s.query.split("/"), tap = parts.slice(0, 2).join("/"), kind = s.kind === "cask" ? "cask" : "formula";
    if (e.type === "action_chosen" && e.action === "qualified-inspect") { s.detail = {name: s.query, kind}; s.detailLoaded = false; s.detailMessage = ""; }
    else {
      if (e.type === "action_chosen" && ["qualified-tap", "qualified-trust"].includes(e.action)) operation = startTask({tool: "homebrew", operation: e.action === "qualified-tap" ? "tap" : "trust", tap}, {notify: true});
      if (e.type === "action_chosen" && e.action === "qualified-back") { s.query = ""; }
      else return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-qualified", title: s.query, resizable: {minHeight: 320}, content: [
        homeNavigation(),
        c.text({id: "qualified-source", text: "This package is from " + tap + ". Adding and trusting a tap are separate Host-confirmed operations. Inspect the package after adding its tap; installation independently rechecks current trust."}),
        c.choiceField({id: "kind", title: "Package Kind", choices: ["formula", "cask"], choiceTitles: ["Command-line Tool", "App"], value: kind}),
        c.actions({id: "qualified-source-actions", actions: [c.button({id: "qualified-tap", title: "Review Adding Tap"}), c.button({id: "qualified-trust", title: "Review Trusting Tap"}), c.button({id: "qualified-inspect", title: "Inspect Package"}), c.button({id: "qualified-back", title: "Back to Search"})]})
      ]}), {state: s, operation});
    }
  }
  if (!["installed", "outdated", "search"].includes(s.mode) && !s.detail) {
    if (s.mode === "autoremove" && e.type === "action_chosen" && e.action === "refresh") {
      dropCache("management-autoremove"); s.manageResult = null; s.autoremoveOutput = false; s.autoremoveTaskMessage = "";
    }
    if (s.mode === "vulnerabilities" && e.type === "action_chosen") {
      if (e.action === "stop-security" && s.securityStatus === "running") { s.securityStatus = "cancelled"; s.securitySource = null; }
      if (e.action === "choose-security" && s.securityStatus !== "running") { s.securityStatus = "selecting"; s.manageDetail = null; s.manageMessage = ""; }
      if (e.action === "retry-security" && s.securityStatus === "failed") {
        s.securityStatus = "running"; s.manageMessage = ""; s.securityAttempt = (s.securityAttempt || 0) + 1;
        s.securitySource = s.securitySession + "-check-" + s.securityRun + "-" + s.securityPosition + "-" + s.securityAttempt;
      }
    }
    if (s.mode === "vulnerabilities" && !s.manageDetail) {
      if (!s.securitySession) {
        // Persist only a generation counter; old reports never start a new check.
        const generation = (rawGet("security-generation") || 0) + 1;
        spinnet.storage.set({key: "security-generation", value: generation});
        for (const key of spinnet.storage.keys()) if (key.startsWith("security-session-")) spinnet.storage.remove(key);
        dropCache("management-vulnerabilities");
        s.securitySession = "security-session-" + generation;
        s.securityStatus = "selecting";
        s.securityInventoryLoaded = false;
      }
      if (e.type === "action_chosen" && e.action === "retry-security-inventory" && s.securityStatus === "selecting") {
        s.securityInventoryMessage = ""; s.securityInventoryLoaded = false; s.securityInventoryAttempt = (s.securityInventoryAttempt || 0) + 1;
      }
      const inventoryID = s.securitySession + "-inventory";
      const inventorySource = inventoryID + "-" + (s.securityInventoryAttempt || 0);
      if (e.type === "source_delivered" && e.source === inventorySource && !s.securityInventoryLoaded) {
        if (e.failure) s.securityInventoryMessage = e.failure.message;
        else {
          const packages = (e.result.packages || []).filter(p => p.kind === "formula").slice(0, 2000).sort((a, b) => a.name.localeCompare(b.name));
          writeCache({key: inventoryID, value: {packages}});
          s.securityInventoryLoaded = true; s.securityInventoryMessage = ""; s.securityInventoryTruncated = !!e.result.truncated;
        }
      }
      if (typeof (e.values || {}).securityFilter === "string" && e.values.securityFilter !== s.securityFilter) { s.securityFilter = e.values.securityFilter; s.securityStart = 0; }
      const inventory = (readCache(inventoryID) || {}).packages || [];
      const matching = inventory.filter(p => !s.securityFilter || (p.name + " " + (p.description || "")).toLowerCase().includes(s.securityFilter.toLowerCase()));
      let chosen = rawGet(s.securitySession + "-chosen") || [];
      if (s.securityStatus === "selecting") {
        if (e.type === "item_action" && e.collection === "security-packages" && e.action === "toggle-security") {
          const pkg = findPackage(matching, e.item);
          if (pkg) chosen = chosen.includes(pkg.name) ? chosen.filter(name => name !== pkg.name) : chosen.concat([pkg.name]);
        }
        if (e.type === "action_chosen" && e.action === "select-security") chosen = Array.from(new Set(chosen.concat(matching.map(p => p.name))));
        if (e.type === "action_chosen" && e.action === "clear-security") chosen = [];
        spinnet.storage.set({key: s.securitySession + "-chosen", value: chosen});
        if ((e.type === "item_action" && e.action === "toggle-security") || (e.type === "action_chosen" && ["select-security", "clear-security"].includes(e.action))) s.securitySelectionMessage = "";
        if (e.type === "action_chosen" && e.action === "start-security" && chosen.length) {
          // The reviewed check returns bare names. Resolve only identities
          // unique across the entire installed inventory, including tools
          // outside the selection and outside this request's first batch.
          const identities = new Map();
          for (const pkg of inventory) {
            const bare = pkg.name.split("/").pop(), matches = identities.get(bare) || new Set();
            matches.add(pkg.name); identities.set(bare, matches);
          }
          const ambiguous = chosen.filter(name => (identities.get(name.split("/").pop()) || new Set()).size > 1);
          if (ambiguous.length) s.securitySelectionMessage = "Homebrew reports the same package name for more than one installed tool. This check cannot distinguish " + ambiguous.slice(0, 8).join(", ") + (ambiguous.length > 8 ? " and " + (ambiguous.length - 8) + " more" : "") + ". Deselect these tools before checking; no security conclusion is available for them.";
          else {
            spinnet.storage.set({key: s.securitySession + "-frozen", value: chosen});
            s.securityStarted = true; s.securityStatus = "running"; s.securityPosition = 0; s.securityRun = (s.securityRun || 0) + 1; s.securityAttempt = 0;
            s.securitySource = s.securitySession + "-check-" + s.securityRun + "-0-0";
            s.securityBatchNames = chosen.slice(0, 20); s.manageResult = null; s.manageMessage = "";
            dropCache("management-vulnerabilities");
          }
        }
      }
      if (s.securityStatus === "selecting") {
        if (e.type === "load_range" && e.collection === "security-packages") { s.securityStart = e.start; s.securityCount = Math.min(e.count, 100); }
        const start = Math.min(s.securityStart || 0, Math.max(0, matching.length - 1));
        const actions = [c.button({id: "select-security", title: "Select All " + matching.length + " Matching Tools"}), c.button({id: "clear-security", title: "Clear Selection"})];
        if (chosen.length) actions.push(c.button({id: "start-security", title: "Check Selected " + chosen.length}));
        if (s.securityInventoryMessage) actions.push(c.button({id: "retry-security-inventory", title: "Retry Loading Installed Tools"}));
        return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-security-select", title: "Security Check", resizable: {minHeight: 360}, content: [
          homeNavigation(),
          c.text({id: "security-scope", text: "Select installed command-line tools to check for known vulnerabilities. Cask Apps are not checked."}),
          c.text({id: "security-data", text: "When you choose Check Selected, OSV receives upstream repository names and installed source versions. This check changes no packages.", style: {color: "secondary"}}),
          c.textField({id: "securityFilter", title: "Find Installed Tools", placeholder: "Name or description", value: s.securityFilter || "", collection: "security-packages"}),
          c.text({id: "security-selection", text: chosen.length + " selected · " + matching.length + " matching of " + inventory.length + " installed tools. Double-click or press Return to select." + (s.securityInventoryTruncated ? ". Inventory reached the Host limit; some installed tools are not listed." : "")}),
          c.actions({id: "security-selection-actions", actions}),
          ...(s.securitySelectionMessage ? [c.text({id: "security-selection-error", text: s.securitySelectionMessage})] : []),
          c.list({id: "security-packages", total: matching.length, start, items: matching.slice(start, start + (s.securityCount || 80)).map(p => c.item({id: packageID(p), title: p.name, text: p.name, icon: {symbol: chosen.includes(p.name) ? "checkmark.circle.fill" : "circle"}, subtitle: [chosen.includes(p.name) ? "Selected" : "Not selected", p.installed_version || p.version, p.description].filter(Boolean).join(" · "), marks: chosen.includes(p.name) ? ["security_selected"] : []})), emptyText: s.securityInventoryMessage || (!s.securityInventoryLoaded ? "Reading installed tools…" : s.securityFilter ? "No matching tools." : "No installed command-line tools."), actions: [c.itemAction({id: "toggle-security", title: "Select for Security Check", default: true, toggle: "security_selected"})]})
        ], sources: watching(!s.securityInventoryLoaded && !s.securityInventoryMessage ? [spinnet.tools.read.source(inventorySource, {tool: "homebrew", operation: "installed", kind: "formula"}, {deliver: true})] : [])}), {state: s});
      }
    }
    if (s.mode === "vulnerabilities" && s.securityStatus === "running" && e.type === "source_delivered" && e.source === s.securitySource) {
      if (e.failure) { s.securityStatus = "failed"; s.manageMessage = e.failure.message; }
      else if (e.result.available === false) { s.securityStatus = "unsupported"; s.manageMessage = "This Homebrew version cannot perform Security Check. " + (e.result.reason || ""); }
      else {
        const prior = rawGet("management-vulnerabilities") || {checked: 0, skipped_count: 0, unaccounted: 0};
        const report = e.result, names = s.securityBatchNames;
        const associate = record => {
          const matches = names.filter(name => name === record.name || name.split("/").pop() === record.name);
          return matches.length === 1 ? Object.assign({}, record, {name: matches[0]}) : null;
        };
        const skipped = (report.skipped || []).map(associate).filter(Boolean);
        const checked = Math.max(0, Math.min(names.length - skipped.length, Number(report.checked) || 0));
        const findings = (report.findings || []).map(associate).filter(Boolean);
        const frozen = rawGet(s.securitySession + "-frozen") || [];
        try {
          appendSecurityReport({available: true, checked: prior.checked + checked, skipped_count: prior.skipped_count + skipped.length, unaccounted: prior.unaccounted + Math.max(0, names.length - checked - skipped.length), processed: s.securityPosition + names.length, total: frozen.length, truncated: !!prior.truncated || !!report.truncated}, findings.concat(skipped.map(p => Object.assign({}, p, {security_skipped: true}))));
          s.securityPosition += names.length;
          s.securityBatchNames = frozen.slice(s.securityPosition, s.securityPosition + 20);
          if (s.securityBatchNames.length) s.securitySource = s.securitySession + "-check-" + s.securityRun + "-" + s.securityPosition + "-" + s.securityAttempt;
          else { s.securityStatus = "complete"; s.securitySource = null; }
        } catch (error) { s.securityStatus = "failed"; s.manageMessage = "Could not retain this report within Plugin Storage limits. Completed results are retained. " + error.message; }
      }
    }
    const data = readCache("management-" + s.mode) || s.manageResult || {};
    const records = s.mode === "vulnerabilities" ? securityRecords(data) : data.services || data.taps || data.findings || data.applications || [];
    if (s.mode !== "vulnerabilities" && e.type === "source_delivered" && sourceIs("manage")) {
      if (e.failure) s.manageMessage = e.failure.message;
      else {
        writeCache({key: "management-" + s.mode, value: e.result});
        s.manageResult = {available: e.result.available, reason: e.result.reason, next_offset: e.result.next_offset}; s.manageMessage = "";
      }
    }
    if (e.type === "item_action" && e.action === "ignore-adoption" && s.mode === "adopt") {
      const app = findManagement(records, e.item);
      if (app) {
        const key = app.identity || app.bundle_id + "|" + app.name, ignored = (rawGet("ignored-adoptions") || []).slice(0, 128), at = ignored.indexOf(key);
        if (at >= 0) ignored.splice(at, 1); else if (ignored.length < 128) ignored.push(key);
        spinnet.storage.set({key: "ignored-adoptions", value: ignored});
      }
    }
    if (e.type === "item_action" && e.action === "manage-details") { s.manageDetail = findManagement(records, e.item) || null; if (!s.manageDetail) s.manageMessage = "This item disappeared after refresh. Choose a current item."; if (s.mode === "adopt") s.caskName = (((s.manageDetail || {}).candidates || [])[0] || {}).name || ""; s.adoption = null; s.adoptionRequest = null; s.adoptionMessage = ""; s.advisory = null; s.advisoryID = null; s.advisoryStart = 0; s.advisoryMessage = ""; s.tapPackages = []; s.tapStart = 0; writeCache({key: "tap-packages", value: {packages: []}}); }
    // Doctor records can exceed the 64 KiB State limit. Keep only an identity
    // between events and resolve the complete current record from Plugin Storage.
    const doctorRecords = s.mode === "doctor" ? ((readCache("management-doctor") || {}).findings || []) : [];
    const doctorDetail = s.mode === "doctor" && s.manageDetail
      ? doctorRecords.find(p => managementID(p) === (s.manageDetail.doctorID || managementID(s.manageDetail))) : null;
    if (s.mode === "doctor" && s.manageDetail) {
      s.manageDetail = doctorDetail ? {doctorID: managementID(doctorDetail)} : null;
      if (!doctorDetail) s.manageMessage = "This finding changed after refresh. Choose a current finding.";
    }
    const controls = [homeNavigation()];
    if (s.manageDetail) controls.push(c.actions({id: "back-navigation", actions: [c.button({id: "manage-back", title: "Back to " + modeTitles[modes.indexOf(s.mode)]})]}));
    else controls.push(c.text({id: "workflow-description", text: ({services: "Manage background services installed with Homebrew.", taps: "Taps are package sources. Adding a tap and trusting it are separate actions.", vulnerabilities: "Check installed command-line tools against known security advisories.", doctor: "Check Homebrew health. Open a finding to review its guidance or supported repair.", adopt: "Bring an existing App under Homebrew management after reviewing its match.", autoremove: "Remove formulae installed only as dependencies that Homebrew no longer needs. Explicitly installed tools and cask Apps are not removed.", cleanup: "Choose what to clean. Clearing the Plugin cache only resets this Plugin's saved results.", activity: "Confirmed work continues after closing this window. Open task details to see results and logs."})[s.mode], style: {color: "secondary"}}));
    const sources = [];
    if (!["cleanup", "activity", "vulnerabilities"].includes(s.mode)) controls.push(c.actions({id: "refresh-controls", actions: [c.button({id: "refresh", title: "Refresh List"})]}));
    if (!["cleanup", "activity", "vulnerabilities"].includes(s.mode) || (s.mode === "vulnerabilities" && s.securityStatus === "running" && !s.manageDetail)) sources.push(spinnet.tools.read.source(s.mode === "vulnerabilities" ? s.securitySource : sourceID("manage"), Object.assign({tool: "homebrew", operation: s.mode === "adopt" ? "adoptionCandidates" : s.mode === "autoremove" ? "previewAutoremove" : s.mode}, s.mode === "vulnerabilities" ? {names: s.securityBatchNames} : {}), {deliver: true}));
    const latest = readCache("management-" + s.mode) || s.manageResult || {};
    if (s.mode === "doctor" && !s.manageDetail) {
      const context = latest.context;
      const incomplete = latest.truncated || !context || context.unverified_directory_checks > 0;
      controls.push(c.text({id: "doctor-scope", title: incomplete && (latest.findings || context) ? "Incomplete Check" : "Check Scope", text: "Checks Homebrew health and reported directory access. Your terminal's shell configuration is not inspected." + (context && context.unverified_directory_checks > 0 ? " " + context.unverified_directory_checks + " directory checks could not be verified; check these in Terminal with brew doctor." : !context && latest.findings ? " Refresh with the updated Host to verify directory access." : "") + (latest.truncated ? " The report reached a result limit; review the complete report in Terminal with brew doctor." : ""), style: {color: "secondary"}}));
    }
    if (s.mode === "autoremove") {
      const packages = latest.packages || [];
      const ready = !s.manageMessage && latest.available === true && latest.dry_run === true && latest.succeeded === true && latest.complete === true && latest.no_op === false && !latest.truncated && packages.length > 0;
      const loaded = latest.succeeded !== undefined || latest.available === false;
      if (s.manageMessage) controls.push(c.text({id: "autoremove-error", text: s.manageMessage}));
      if (s.autoremoveTaskMessage) controls.push(c.text({id: "autoremove-task-message", text: s.autoremoveTaskMessage}));
      controls.push(c.text({id: "autoremove-status", title: "Removal Preview", text: s.manageMessage ? "Could not refresh the preview. Use Refresh to retry." : !loaded ? "Checking for unused dependencies…" : latest.available === false ? "This Homebrew version is not supported by the reviewed preview." : latest.succeeded !== true || latest.complete !== true ? "Homebrew could not produce a complete removal plan. No removal is available." : !packages.length || latest.no_op ? "No unused dependencies to remove." : packages.length + (packages.length === 1 ? " unused dependency" : " unused dependencies") + " would be uninstalled."}));
      controls.push(c.text({id: "autoremove-help", text: "This preview changes nothing. Review Removal opens the Host confirmation with the exact dependencies; execution rechecks the plan. Completed work and output appear in Tasks and Logs.", style: {color: "secondary"}}));
      if (e.type === "action_chosen" && e.action === "review-autoremove" && ready) { s.autoremoveTaskMessage = ""; operation = startTask({tool: "homebrew", operation: "autoremove"}, {notify: true}); }
      if (e.type === "action_chosen" && e.action === "autoremove-output") s.autoremoveOutput = !s.autoremoveOutput;
      const actions = ready ? [c.button({id: "review-autoremove", title: "Review Removal…"})] : [];
      if (loaded && (latest.stdout || latest.stderr)) actions.push(c.button({id: "autoremove-output", title: s.autoremoveOutput ? "Hide Preview Output" : "Show Preview Output"}));
      if (actions.length) controls.push(c.actions({id: "autoremove-controls", actions}));
      if (s.autoremoveOutput) controls.push(c.text({id: "autoremove-output-text", text: [latest.stdout, latest.stderr].filter(Boolean).join("\n").slice(0, 8192)}));
      if (e.type === "load_range" && e.collection === "autoremove-packages") { s.autoremoveStart = e.start; s.autoremoveCount = Math.min(e.count, 100); }
      const start = Math.min(s.autoremoveStart || 0, Math.max(0, packages.length - 1));
      controls.push(c.list({id: "autoremove-packages", total: packages.length, start, items: packages.slice(start, start + (s.autoremoveCount || 80)).map(p => c.item({id: packageID(p), title: p.name, text: p.name, subtitle: "Unused dependency · will be uninstalled"})), emptyText: !loaded ? "Reading Homebrew's removal preview…" : "No dependencies available for removal."}));
      return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-manage-autoremove", title: "Remove Unused Dependencies", resizable: {minHeight: 320}, content: controls, sources: watching(sources)}), {state: s, operation});
    }
    if (s.manageMessage) controls.push(c.text({id: "message", text: s.manageMessage}));
    if (["services", "taps"].includes(s.mode) && !s.manageDetail) {
      const records = latest[s.mode];
      const status = s.manageMessage ? "Could not load " + s.mode + ". See the error above and use Refresh to retry." : !records ? "Loading " + (s.mode === "taps" ? "package sources" : "services") + "…" : s.mode === "services" ? records.length ? records.length + " services found. Open a service to view its status and controls." : "No services found. Only installed packages that provide a background service appear here." : records.length ? records.length + (records.length === 1 ? " package source" : " package sources") + ". Open a source to see its packages and trust settings." : "No additional package sources found. Official packages can be provided by Homebrew's catalogue without a checked-out tap.";
      controls.push(c.text({id: "management-status", text: status, style: {color: "secondary"}}));
    }
    if (latest.truncated && s.mode !== "vulnerabilities") controls.push(c.text({id: "management-bound", title: "Bounded Results", text: s.mode === "adopt" ? "Automatic matching inspected at most 50 matching casks. Some matches may be absent; unmatched Apps can still review an exact cask name." : "This report reached the Host result or repair-target limit. Refresh after completing reviewed work to see remaining findings."}));
    if (latest.available === false) controls.push(c.text({id: "unavailable", text: "This workflow requires Homebrew 7 or newer. " + (latest.reason || "")}));
    if (s.mode === "vulnerabilities" && !s.manageDetail) {
      const frozen = rawGet(s.securitySession + "-frozen") || [];
      const actions = s.securityStatus === "running" ? [c.button({id: "stop-security", title: "Stop Check"})] : [c.button({id: "choose-security", title: "Choose Tools"})];
      if (s.securityStatus === "failed") actions.unshift(c.button({id: "retry-security", title: "Retry Failed Check"}));
      controls.push(c.actions({id: "security-check-actions", actions}));
      if (s.securityStatus === "cancelled") controls.push(c.text({id: "security-stopped", text: "Check stopped. Completed results are retained; remaining selected tools have not been checked."}));
      if (s.securityStatus === "failed") controls.push(c.text({id: "security-failed", text: "Check paused after an error. Completed results are retained. Retry resumes the failed tools; no tools are skipped automatically."}));
      const skipped = latest.skipped_count === undefined ? (latest.skipped || []).length : latest.skipped_count, unknown = latest.unaccounted || 0;
      const incomplete = !!latest.truncated || skipped > 0 || unknown > 0 || s.securityStatus !== "complete";
      controls.push(c.text({id: "security-coverage", title: s.securityStatus === "running" ? "Checking Selected Tools…" : incomplete ? "Incomplete Check" : "Check Complete", text: (latest.processed || 0) + "/" + frozen.length + " processed · " + (latest.checked || 0) + " checked · " + skipped + " not checked · " + unknown + " not accounted for." + (latest.truncated ? " Advisory results reached a limit; review is incomplete." + (latest.omitted ? " " + latest.omitted + " package result rows could not be retained. Choose fewer tools to review them separately." : "") : "")}));
      controls.push(c.text({id: "security-results-help", text: "Results apply only to your selected command-line tools. Open a package to review advisories or why it was not checked. Cask Apps are not checked.", style: {color: "secondary"}}));
    }
    if (s.mode === "doctor" && latest.fix_all && !s.manageDetail) {
      const batch = latest.fix_all;
      const canPreview = Array.isArray(batch.repairs) && batch.repairs.length === batch.count;
      if (canPreview) {
        controls.push(c.text({id: "supported-repairs", text: batch.count + " available repairs. Review the exact operations before continuing. Other findings may still need manual attention."}));
        controls.push(c.actions({id: "doctor-batch", actions: [c.button({id: "fix-all", title: "Review Available Repairs (" + batch.count + ")"})]}));
        if (e.type === "action_chosen" && e.action === "fix-all") s.doctorRepairs = batch.target;
      }
      if (e.type === "action_chosen" && e.action === "cancel-doctor-repairs") s.doctorRepairs = null;
      if (s.doctorRepairs && s.doctorRepairs !== batch.target) s.doctorRepairs = null;
      if (canPreview && s.doctorRepairs === batch.target) {
        const preview = [c.actions({id: "doctor-repair-back", actions: [c.button({id: "cancel-doctor-repairs", title: "Back to Doctor"})]}),
          c.text({id: "doctor-repair-list", title: "Available Repairs", text: batch.repairs.map((repair, i) => (i + 1) + ". " + repair.title).join("\n\n")}),
          c.text({id: "doctor-repair-help", text: "Continue to review these operations in the Host confirmation. Administrator authorization is requested only if a selected repair needs it. This does not fix every Doctor finding."}),
          c.actions({id: "doctor-repair-continue", actions: [c.button({id: "confirm-doctor-repairs", title: "Continue to Host Confirmation"})]})];
        if (e.type === "action_chosen" && e.action === "confirm-doctor-repairs") operation = startTask({tool: "homebrew", operation: "doctorFix", target: batch.target}, {notify: true});
        return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-doctor-repairs", title: "Review Doctor Repairs", resizable: {minHeight: 320}, content: preview}), {state: s, operation});
      }
    }
    const selected = s.mode === "doctor" ? doctorDetail : s.manageDetail;
    if (selected) {
      controls.push(c.text({id: "detail-title", text: s.mode === "doctor" ? managementTitle(selected) : selected.name || selected.text || "Finding", style: {font_size: 18, font_weight: "semibold"}}));
      if (s.mode === "services") {
        controls.push(c.text({id: "service-state", text: "Status: " + selected.status + (selected.user_owned ? " · user-owned service" : " · system-owned service")}));
        if (selected.user_owned) controls.push(c.actions({id: "service-controls", actions: ["serviceStart", "serviceStop", "serviceRestart"].map((id, i) => c.button({id, title: ["Start", "Stop", "Restart"][i]}))}));
        if (e.type === "action_chosen" && e.action.startsWith("service")) operation = startTask({tool: "homebrew", operation: e.action, name: selected.name}, {notify: true});
      }
      if (s.mode === "taps") {
        controls.push(c.text({id: "tap-info", text: [selected.remote, selected.trusted ? "Trusted" : "Not trusted", String(selected.formula_count || 0) + " tools", String(selected.cask_count || 0) + " Apps"].filter(Boolean).join(" · ")}));
        const actions = selected.official ? [] : [c.button({id: selected.trusted ? "untrust" : "trust", title: selected.trusted ? "Stop Trusting" : "Trust This Tap"}), c.button({id: "untap", title: "Remove Tap"})];
        if (actions.length) controls.push(c.actions({id: "tap-controls", actions}));
        sources.push(spinnet.tools.read.source("tap-packages", {tool: "homebrew", operation: "taps", tap: selected.name}, {deliver: true}));
        if (e.type === "source_delivered" && e.source === "tap-packages") { if (e.failure) s.tapPackageMessage = e.failure.message; else { const packages = ((e.result.taps || [])[0] || {}).packages || []; writeCache({key: "tap-packages", value: {packages}}); s.tapPackages = []; } }
        if (s.tapPackageMessage) controls.push(c.text({id: "tap-message", text: s.tapPackageMessage}));
        const tapCache = readCache("tap-packages");
        const tapPackages = (tapCache && tapCache.packages) || s.tapPackages || [];
        if (e.type === "load_range" && e.collection === "tap-packages") { s.tapStart = e.start; s.tapCount = Math.min(e.count, 100); }
        const tapStart = Math.min(s.tapStart || 0, Math.max(0, tapPackages.length - 1));
        controls.push(c.list({id: "tap-packages", total: tapPackages.length, start: tapStart, items: tapPackages.slice(tapStart, tapStart + (s.tapCount || 80)).map((p, i) => c.item({id: packageID(p), text: p.name, title: p.name, subtitle: p.kind === "cask" ? "App" : "Command-line Tool"})), emptyText: "Loading or no packages", actions: [c.itemAction({id: "tap-package", title: "Show Package Details", default: true})]}));
        
        if (e.type === "action_chosen" && ["trust", "untrust", "untap"].includes(e.action)) operation = startTask({tool: "homebrew", operation: e.action, tap: selected.name}, {notify: true});
      }
      if (s.mode === "doctor") {
        controls.push(c.text({id: "doctor-explanation", title: "What Was Found", text: selected.text || "Finding"}));
        if ((selected.affects || []).length) controls.push(c.text({id: "doctor-affected", title: "Affected Items", text: selected.affects.map(value => "• " + value).join("\n")}));
        if (selected.guidance) controls.push(c.text({id: "recommendation-guidance", title: "Recommended Next Steps", text: selected.guidance}));
        if ((selected.links || []).length) controls.push(c.actions({id: "guidance-links", actions: selected.links.map((link, i) => spinnet.open.url.action(link, {id: "doctor-link-" + i, title: "Open Reference " + (i + 1)}))}));
        for (const [i, command] of (selected.commands || []).entries()) controls.push(c.text({id: "command-text-" + i, title: "Terminal Command " + (i + 1), text: "```\n" + command + "\n```"}));
        if ((selected.commands || []).length) controls.push(c.actions({id: "doctor-copy-commands", actions: selected.commands.map((command, i) => spinnet.clipboard.write.action(command, {id: "copy-" + i, title: "Copy Command " + (i + 1)}))}));
        if ((selected.repairs || []).length) {
          controls.push(c.text({id: "doctor-available-repairs", title: "Available Repairs", text: selected.repairs.map((repair, i) => (i + 1) + ". " + repair.title).join("\n\n")}));
          controls.push(c.actions({id: "doctor-repair-actions", actions: selected.repairs.map((repair, i) => c.button({id: "fix-" + i, title: "Review Repair " + (i + 1)}))}));
        }
        if (e.type === "action_chosen" && e.action.startsWith("fix-")) {
          const repair = (selected.repairs || [])[Number(e.action.slice(4))];
          if (repair) operation = startTask({tool: "homebrew", operation: "doctorFix", target: repair.target}, {notify: true});
        }
        if (selected.truncated) controls.push(c.text({id: "doctor-detail-incomplete", text: "This finding reached a result limit. Some text or commands were omitted; incomplete commands cannot be copied. Review the complete report in Terminal with brew doctor."}));
        controls.push(c.text({id: "doctor-guidance", text: (selected.repairs || []).length ? "Available repairs open a Host confirmation before running. Terminal commands above are copied only; review them before using them." : "This finding needs manual review. No automatic repair is available. Terminal commands, if shown, are copied only."}));
      }
      if (s.mode === "adopt") {
        controls.push(c.text({id: "application-version", text: [selected.bundle_id, selected.version].filter(Boolean).join(" · ")}));
        const candidates = selected.candidates || [];
        if (candidates.length) {
          controls.push(c.choiceField({id: "caskName", title: "Matched Homebrew App", choices: candidates.map(p => p.name), choiceTitles: candidates.map(p => p.name + " · " + p.confidence), value: s.caskName || candidates[0].name}));
          const match = candidates.find(p => p.name === (s.caskName || candidates[0].name));
          if (match) controls.push(c.text({id: "match-confidence", title: match.confidence === "cannot" ? "Can't Adopt" : "Match Confidence", text: match.reason}));
        } else controls.push(c.textField({id: "caskName", title: "No Automatic Match — Review a Cask", value: s.caskName || "", placeholder: "Exact cask name"}));
        controls.push(c.actions({id: "adoption-review", actions: [c.button({id: "preview-adoption", title: "Review Adoption"})]}));
        if (e.type === "action_chosen" && e.action === "preview-adoption" && /^[a-z0-9][a-z0-9+_.@-]{0,63}$/.test(s.caskName || "")) {
          s.adoption = null; s.adoptionMessage = ""; s.adoptionRefresh = (s.adoptionRefresh || 0) + 1;
          s.adoptionRequest = {tool: "homebrew", operation: "adoptionPreview", target: selected.target, name: s.caskName};
        }
        const adoptionSource = "adoption" + (s.adoptionRefresh ? "-" + s.adoptionRefresh : "");
        if (s.adoptionRequest) sources.push(spinnet.tools.read.source(adoptionSource, s.adoptionRequest, {deliver: true}));
        if (e.type === "source_delivered" && e.source === adoptionSource && s.adoptionRequest) {
          s.adoption = null;
          if (e.failure) { s.adoptionMessage = e.failure.message; s.adoptionRequest = null; }
          else if (e.result && e.result.succeeded === true && typeof e.result.target === "string" && e.result.target.startsWith("adoption_") && e.result.target.length <= 80) { s.adoption = e.result; s.adoptionMessage = ""; }
          else { s.adoptionMessage = (e.result && (e.result.summary || e.result.stderr || e.result.stdout)) || "The Host could not confirm adoption of this App."; s.adoptionRequest = null; }
        }
        if (s.adoptionMessage) controls.push(c.text({id: "adoption-message", text: String(s.adoptionMessage).slice(0, 8192)}));
        if (s.adoption && s.adoptionRequest && s.adoptionRequest.target === selected.target && s.adoptionRequest.name === s.caskName) {
          controls.push(c.text({id: "adoption-summary", text: s.adoption.summary || "Host-reviewed adoption is ready."}));
          controls.push(c.actions({id: "adopt-control", actions: [c.button({id: "adopt", title: "Adopt This App"})]}));
          if (e.type === "action_chosen" && e.action === "adopt") operation = startTask({tool: "homebrew", operation: "adopt", target: s.adoption.target}, {notify: true});
        }
      }

      if (s.mode === "vulnerabilities" && selected.security_skipped) {
        controls.push(c.text({id: "security-skip-reason", title: "Not Checked", text: skipReason(selected)}));
        controls.push(c.text({id: "security-skip-help", text: "No security conclusion is available for this package. Check its upstream security guidance manually.", style: {color: "secondary"}}));
      }
      if (s.mode === "vulnerabilities" && !selected.security_skipped) {
        if (e.type === "action_chosen" && e.action === "advisory-back") { s.advisoryID = null; s.advisory = null; s.advisoryMessage = ""; }
        const advisories = selected.advisories || [];
        if (e.type === "action_chosen" && e.action === "next-advisories") s.advisoryStart = Math.min((s.advisoryStart || 0) + 10, Math.max(0, advisories.length - 1));
        if (e.type === "action_chosen" && e.action === "previous-advisories") s.advisoryStart = Math.max(0, (s.advisoryStart || 0) - 10);
        const start = Math.min(s.advisoryStart || 0, Math.max(0, advisories.length - 1));
        controls.push(c.text({id: "security-partition", title: "What These Results Mean", text: (selected.open_count || 0) + " unresolved · " + (selected.unknown_count || 0) + " need review · " + (selected.patched_count || 0) + " patched by Homebrew. Unresolved advisories match the installed source; unknown means patch applicability could not be established. Patched advisories match a fix in the applicable Homebrew recipe."}));
        const statusTitle = status => ({open: "Unresolved", patched: "Patched by Homebrew", unknown: "Needs Review"})[status] || "Needs Review";
        controls.push(c.list({id: "security-advisories", total: Math.min(10, advisories.length - start), start: 0,
          items: advisories.slice(start, start + 10).map(advisory => c.item({id: advisory.id, title: advisory.id, text: advisory.id, subtitle: statusTitle(advisory.status) + " · " + (advisory.summary || "No summary").split(/\r?\n/)[0].slice(0, 300)})),
          emptyText: "No advisories reported for this package.", actions: [c.itemAction({id: "read-advisory", title: "Read Advisory", default: true})]}));
        if (e.type === "item_action" && e.collection === "security-advisories" && e.action === "read-advisory") {
          const advisory = advisories.find(a => a.id === e.item.id && a.id === (e.item.text || e.item.id));
          if (advisory) { s.advisoryID = advisory.id; s.advisory = null; s.advisoryMessage = ""; }
        }
        const pages = [];
        if (start > 0) pages.push(c.button({id: "previous-advisories", title: "Previous Advisories"}));
        if (start + 10 < advisories.length) pages.push(c.button({id: "next-advisories", title: "More Advisories"}));
        if (pages.length) controls.push(c.actions({id: "advisory-pages", actions: pages}));
        if (e.type === "action_chosen" && advisories.some(a => "advisory-" + a.id === e.action)) { s.advisoryID = e.action.slice(9); s.advisory = null; s.advisoryMessage = ""; }
        if (s.advisoryID) sources.push(spinnet.tools.read.source("advisory", {tool: "homebrew", operation: "vulnerabilityDetail", id: s.advisoryID}, {deliver: true}));
        if (e.type === "source_delivered" && e.source === "advisory") { if (e.failure) { s.advisoryMessage = e.failure.message; s.advisory = null; } else { s.advisory = e.result.advisory; s.advisoryMessage = ""; } }
        if (s.advisoryID || s.advisory) {
          if (e.type === "action_chosen" && e.action === "advisory-back") { s.advisoryID = null; s.advisory = null; s.advisoryMessage = ""; }
          else {
            const detail = s.advisory || {}, detailContent = [
              c.text({id: "advisory-detail", title: detail.id || s.advisoryID, text: s.advisoryMessage || String(detail.details || detail.summary || "Loading advisory…").slice(0, 8192)}),
              c.text({id: "advisory-status", text: statusTitle(((selected.advisories || []).find(a => a.id === (detail.id || s.advisoryID)) || {}).status)}),
              c.text({id: "advisory-fixes", title: "Upstream Fixed Versions Mentioned", text: (detail.fixed_versions || []).join(", ") || "No upstream fixed version listed. This does not establish a Homebrew upgrade fix."})
            ];
            for (const [i, url] of (detail.references || []).entries()) detailContent.push(c.actions({id: "advisory-reference-" + i, actions: [spinnet.open.url.action(url, {id: "advisory-reference-open-" + i, title: "Open Reference " + (i + 1)})]}));
            detailContent.push(c.actions({id: "advisory-navigation", actions: [c.button({id: "advisory-back", title: "Back to Package Advisories"})]}));
            return spinnet.ui.showPage(spinnet.ui.page({id: "homebrew-advisory", title: detail.id || s.advisoryID || "Security Advisory", content: detailContent, sources: watching(s.advisoryID ? [spinnet.tools.read.source("advisory", {tool: "homebrew", operation: "vulnerabilityDetail", id: s.advisoryID}, {deliver: true})] : [])}), {state: s});
          }
        }
        if (selected.upgrade_available === true) {
          controls.push(c.text({id: "security-upgrade-help", text: "An eligible upgrade is available. It has not been verified to fix these advisories; review the upstream guidance before upgrading.", style: {color: "secondary"}}));
          controls.push(c.actions({id: "security-upgrade", actions: [c.button({id: "upgrade-security", title: "Review Available Package Upgrade"})]}));
          if (e.type === "action_chosen" && e.action === "upgrade-security") operation = startTask({tool: "homebrew", operation: "upgrade", kind: "formula", name: selected.name}, {notify: true});
        }
      }
    } else if (s.mode === "cleanup") {
      controls.push(c.choiceField({id: "pruneDays", title: "Remove Eligible Downloads Older Than", choices: ["120", "30", "all"], choiceTitles: ["120 Days", "30 Days", "All Ages"], value: s.pruneDays || "120"}));
      controls.push(c.text({id: "cleanup-warning", text: "Clean Up removes eligible cached downloads and old package versions. To uninstall unused dependencies, open Remove Unused Dependencies from Homebrew Home."}));
      controls.push(c.actions({id: "cleanup-controls", actions: [c.button({id: "cleanup", title: "Clean Up"}), c.button({id: "clear-cache", title: "Clear Plugin Cache"})]}));
      if (e.type === "action_chosen" && e.action === "cleanup") operation = startTask(Object.assign({tool: "homebrew", operation: "cleanup"}, s.pruneDays === "all" ? {pruneAll: true} : {days: Number(s.pruneDays || 120)}), {notify: true});
      if (e.type === "action_chosen" && e.action === "clear-cache") { spinnet.storage.clear(); s.packages = []; s.manageResult = null; s.manageMessage = "Plugin Cache Cleared"; controls.push(c.text({id: "cache-result", text: s.manageMessage})); }
    } else if (s.mode === "activity") {
      controls.push(c.activityList({id: "own-activities", emptyText: "No Homebrew work is running"}));
      controls.push(c.text({id: "activity-help", text: "You can stop your confirmed Homebrew Tasks here or from the Spinnet Status Item."}));
      controls.push(c.actions({id: "activity-details", actions: [c.button({id: "task-details", title: "Task Details and Logs"})]}));
    } else {
      if (s.mode === "taps") {
        controls.push(c.textField({id: "tapName", title: "Add a Tap", placeholder: "owner/repository", value: s.tapName || ""}));
        controls.push(c.actions({id: "add-tap", actions: [c.button({id: "tap", title: "Review Adding Tap"})]}));
        if (e.type === "action_chosen" && e.action === "tap" && /^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*$/.test(s.tapName || "")) operation = startTask({tool: "homebrew", operation: "tap", tap: s.tapName}, {notify: true});
      }
      let items = (s.mode === "vulnerabilities" ? securityRecords(latest) : latest.services || latest.taps || latest.findings || latest.applications || []).map((p, position) => Object.assign({position}, p));
      let managementSections;
      if (s.mode === "doctor") {
        items.sort((a, b) => Number(!!(b.repairs || []).length) - Number(!!(a.repairs || []).length));
        managementSections = [true, false].map(available => c.section({id: available ? "repairs" : "manual", title: available ? "Available Repairs" : "Manual Review", count: items.filter(p => !!(p.repairs || []).length === available).length})).filter(section => section.count);
      }
      if (s.mode === "vulnerabilities") {
        const groups = ["review", "patched", "skipped"], titles = ["Needs Review", "Patched by Homebrew", "Not Checked"];
        items.sort((a, b) => groups.indexOf(securityGroup(a)) - groups.indexOf(securityGroup(b)));
        managementSections = groups.map((group, i) => c.section({id: group, title: titles[i], count: items.filter(p => securityGroup(p) === group).length})).filter(section => section.count);
      }
      if (s.mode === "adopt") {
        const ignored = rawGet("ignored-adoptions") || [], filter = s.adoptionFilter || "active";
        controls.push(c.choiceField({id: "adoptionFilter", title: "Matches", choices: ["active", "ignored", "all"], choiceTitles: ["Available Matches", "Ignored Apps", "All Apps"], value: filter}));
        const groups = ["ready", "likely", "unlikely", "cannot", "unmatched"], titles = ["Ready to Adopt", "Likely Adoptable", "Unlikely Adoptions", "Can't Adopt", "No Automatic Match"];
        items = items.filter(p => filter === "all" || ignored.includes(p.identity || p.bundle_id + "|" + p.name) === (filter === "ignored"));
        items.sort((a, b) => groups.indexOf(((a.candidates || [])[0] || {}).confidence || "unmatched") - groups.indexOf(((b.candidates || [])[0] || {}).confidence || "unmatched"));
        managementSections = groups.map((group, i) => c.section({id: group, title: titles[i], count: items.filter(p => (((p.candidates || [])[0] || {}).confidence || "unmatched") === group).length})).filter(section => section.count);
      }
      if (e.type === "load_range" && e.collection === "management") { s.managementStart = e.start; s.managementCount = Math.min(e.count, 100); }
      const managementStart = Math.min(s.managementStart || 0, Math.max(0, items.length - 1));
      controls.push(c.list({id: "management", total: items.length, start: managementStart, sections: managementSections && managementSections.length ? managementSections : undefined, items: items.slice(managementStart, managementStart + (s.managementCount || 80)).map((p, i) => c.item({id: managementID(p), text: managementText(p), title: managementTitle(p), subtitle: s.mode === "vulnerabilities" ? p.security_skipped ? "Not checked · open for explanation" : (p.open_count || 0) + " unresolved · " + (p.unknown_count || 0) + " need review · " + (p.patched_count || 0) + " patched" : p.status || p.version || (p.trusted ? "Trusted" : p.advisories ? p.advisories.length + " advisories" : "")})), emptyText: s.manageMessage || latest.available === false ? "Results unavailable. See the message above." : !readCache("management-" + s.mode) && !s.manageResult ? "Loading " + modeTitles[modes.indexOf(s.mode)] + "…" : ({services: "No services found.", taps: "No taps found.", vulnerabilities: "No findings in the checked packages. Review coverage above.", doctor: "No Doctor findings reported.", adopt: "No Apps found for adoption."})[s.mode] || "No results.", actions: [c.itemAction({id: "manage-details", title: "Show Details", default: true})].concat(s.mode === "adopt" ? [c.itemAction({id: "ignore-adoption", title: s.adoptionFilter === "ignored" ? "Restore Match" : "Ignore or Restore Match"})] : [])}));
    }
    return spinnet.ui.showPage(spinnet.ui.page({id: selected ? "homebrew-manage-detail-" + managementID(selected) : "homebrew-manage-" + s.mode, title: selected ? managementTitle(selected) : modeTitles[modes.indexOf(s.mode)], resizable: {minHeight: 320}, content: controls, sources: watching(sources)}), {state: s, operation});
  }
  if (e.type === "item_action" && e.action === "details") {
    const held = readCache("packages-" + s.mode);
    s.detail = findPackage((held && held.packages) || s.packages, e.item) || null;
    if (!s.detail) s.message = "This package disappeared after refresh. Choose a current package.";
    s.detailLoaded = false;
    s.previewInput = null; s.preview = null; s.previewMessage = "";
    s.analyticsInput = null; s.analytics = null; s.analyticsMessage = ""; s.zap = "off"; s.language = null; s.packageOptions = false;
  }
  if (e.type === "action_chosen" && e.action === "back") { s.detail = null; s.packageOptions = false; }
  if (e.type === "action_chosen" && e.action === "package-options") s.packageOptions = true;
  if (e.type === "action_chosen" && e.action === "package-options-back") { s.packageOptions = false; s.zap = "off"; s.analyticsInput = null; }
  if (s.detail) {
    const pkg = s.detail;
    const detailSourceID = "detail" + (s.detailRefresh ? "-" + s.detailRefresh : "");
    if (e.type === "source_delivered" && e.source === detailSourceID) {
      s.detailLoaded = true;
      if (e.failure) s.detailMessage = e.failure.message;
      else { s.detail = Object.assign({}, pkg, (e.result.packages || [])[0] || {}); s.detailMessage = (e.result.not_found || []).length ? "This package is no longer in the local catalogue." : ""; }
    }
    const p = s.detail;
    if (e.type === "action_chosen" && e.action === "analytics") s.analyticsInput = {tool: "homebrew", operation: "packageAnalytics", kind: p.kind, names: [p.name]};
    if (e.type === "source_delivered" && e.source === "analytics") { if (e.failure) s.analyticsMessage = e.failure.message; else s.analytics = e.result; }
    const content = [
      homeNavigation(),
      c.actions({id: "navigation", actions: [c.button({id: s.packageOptions ? "package-options-back" : "back", title: s.packageOptions ? "Back to Package" : "Back to " + (modeTitles[modes.indexOf(s.mode)] || "Packages")})]}),
      c.text({id: "name", text: p.title || p.name, style: {fontSize: 20, fontWeight: "semibold"}}),
      c.text({id: "description", text: p.description || (s.detailLoaded ? "No description available." : "Loading package details…")}),
      c.adaptive({id: "package-facts", minCardWidth: 240, spacing: 12, maxColumns: 2, content: [c.column({id: "available-card", content: [c.text({id: "version", title: "Available Version", text: p.version || "Unknown"})]}), c.column({id: "installed-card", content: [c.text({id: "installed", title: "Installed Version", text: p.installed_version || "Not installed"})]})]}),
      c.text({id: "warnings", text: [s.detailMessage, p.needs_privileges ? "This App requires administrator privileges." : "", p.quits_app ? "Upgrading this App may quit it first." : "", p.pinned ? "This package is pinned. Unpin it in Package Options before upgrading or uninstalling." : p.outdated ? "An update is available." : ""].filter(Boolean).join("\n")})
    ];
    if (p.kind === "cask" && p.auto_updates) content.push(c.text({id: "auto-update-warning", text: "This App may update itself even when its Homebrew version is pinned."}));
    if (!s.packageOptions) {
      const primary = (p.installed_version ? [p.outdated && !p.pinned ? c.button({id: "upgrade", title: "Upgrade…"}) : null, p.pinned ? null : c.button({id: "uninstall", title: "Uninstall…"})] : [c.button({id: "install", title: "Install…"})]).filter(Boolean);
      primary.push(c.button({id: p.installed_version ? "previewUpgrade" : "previewInstall", title: p.installed_version ? "Preview Upgrade" : "Preview Installation"}));
      content.push(c.actions({id: "package-controls", actions: primary}), c.actions({id: "package-options-navigation", actions: [c.button({id: "package-options", title: "Package Options and Links…"})]}));
      content.push(c.text({id: "operation-help", text: "Install, upgrade and uninstall open a confirmation before anything changes.", style: {color: "secondary"}}));
    } else {
      content.push(c.text({id: "source", title: "Package Source", text: p.tap || "Unknown"}), c.text({id: "dependencies", title: "Dependencies", text: ((p.dependencies || []).join(", ") || "None listed").slice(0, 4096)}));
      if (p.installed_version) content.push(c.actions({id: "pin-controls", actions: [c.button({id: p.pinned ? "unpin" : "pin", title: p.pinned ? "Unpin Version…" : "Pin Version…"})]}));
      const secondary = [c.button({id: "check-updates", title: "Update Homebrew Catalog…"}), c.button({id: "analytics", title: "Package Popularity"})];
      if (p.pinned) content.push(c.text({id: "pinned-lock", text: "Unpin this package before upgrading or uninstalling it."}));
      if (p.installed_version && p.linkable !== false) {
        if (p.linked !== true) secondary.push(c.button({id: "link", title: "Preview Linking Files"}));
        if (p.linked !== false) secondary.push(c.button({id: "unlink", title: "Preview Unlinking Files"}));
      }
      if (p.homepage) secondary.push(spinnet.open.url.action(p.homepage, {id: "homepage", title: "Open Homepage"}));
      const links = [];
      if (p.homepage) links.push(spinnet.clipboard.write.action(p.homepage, {id: "homepage-copy", title: "Copy Homepage URL"}));
      const catalogName = String(p.name || "").split("/").pop();
      if (p.official === true && ["formula", "cask"].includes(p.kind) && /^[a-z0-9][a-z0-9+_.@-]{0,63}$/.test(catalogName)) {
        const url = "https://formulae.brew.sh/" + p.kind + "/" + encodeURIComponent(catalogName);
        links.push(spinnet.open.url.action(url, {id: "package-page", title: "Open Homebrew Package Page"}), spinnet.clipboard.write.action(url, {id: "package-page-copy", title: "Copy Homebrew Package URL"}));
      }
      if (links.length) content.push(c.actions({id: "package-links", actions: links}));
      if (p.download_url) secondary.push(spinnet.clipboard.write.action(p.download_url, {id: "download-link", title: "Copy Download Link"}));
      content.push(c.actions({id: "more-package-controls", actions: secondary}));
      if (p.kind === "cask" && p.installed_version && !p.pinned) content.push(c.choiceField({id: "zap", title: "App Uninstall", choices: ["off", "on"], choiceTitles: ["Keep Related Files", "Remove Related Files Too"], value: s.zap || "off"}), c.actions({id: "advanced-uninstall", actions: [c.button({id: "uninstall", title: "Review App Uninstall…"})]}));
      if (s.analytics) content.push(c.text({id: "popularity", title: "Install Popularity", text: ["30d", "90d", "365d"].map(period => "Last " + period.replace("d", " Days") + ": " + ((((s.analytics.analytics || {}).install || {})[period]) === undefined ? "Unavailable" : ((s.analytics.analytics || {}).install || {})[period]) + " installs").join(" · ")}));
      if (s.analyticsMessage) content.push(c.text({id: "popularity-message", text: s.analyticsMessage}));
      if (p.installed_path) content.push(c.actions({id: "package-path", actions: [spinnet.open.path.action(p.installed_path, {id: "open-path", title: "Open Package Folder"}), spinnet.clipboard.write.action(p.installed_path, {id: "copy-path", title: "Copy Package Path"})]}));
      if (p.kind === "cask" && p.installed_version && (p.languages || []).length) {
        content.push(c.choiceField({id: "language", title: "App Language", choices: p.languages, value: s.language || p.selected_language || p.languages[0]}), c.actions({id: "language-controls", actions: [c.button({id: "change-language", title: "Review Language Change"})]}));
      }
    }
    const sources = [spinnet.tools.read.source(detailSourceID, {tool: "homebrew", operation: "info", kind: p.kind, names: [p.name]}, {deliver: true})];
    if (s.detailRefresh) sources.push(spinnet.tools.read.source("version-" + s.detailRefresh, {tool: "homebrew", operation: "version"}, {deliver: true}));
    if (e.type === "source_delivered" && e.source === "version-" + s.detailRefresh && !e.failure) { s.toolVersion = e.result.version; s.toolFeatures = e.result.features; }
    if (s.analyticsInput) sources.push(spinnet.tools.read.source("analytics", s.analyticsInput, {deliver: true}));
    return spinnet.ui.showPage(spinnet.ui.page({id: (s.packageOptions ? "homebrew-options-" : "homebrew-detail-") + packageID(p), title: s.packageOptions ? p.name + " · Options" : p.name, resizable: {minHeight: 320}, content,
      sources: watching(sources)}), {state: s, operation});
  }
  if (e.type === "action_chosen" && e.action === "filter-options") s.filterOptions = !s.filterOptions;
  const validQuery = /^[a-z0-9+_.@][a-z0-9+_.@-]{1,63}$/.test(s.query);
  const request = {tool: "homebrew", operation: s.mode};
  if (s.kind !== "both") request.kind = s.kind;
  if (s.mode === "search") request.query = s.query;
  if (s.mode === "outdated") request.greedy = s.greedy === "on";
  const definition = JSON.stringify(request);
  if (s.definition !== definition) {
    s.definition = definition; s.packages = []; s.loading = s.mode !== "search" || validQuery; s.message = "";
  }
  if (e.type === "source_delivered" && sourceIs("packages")) {
    s.loading = false;
    if (e.failure) s.message = e.failure.message;
    else {
      const packages = e.result.packages || [];
      writeCache({key: "packages-" + s.mode, value: {definition, packages}});
      s.packages = []; s.total = packages.length; s.truncated = !!e.result.truncated;
      if (s.mode === "outdated") {
        const selectionDefinition = definition + "-" + s.refresh;
        if (s.selectionDefinition !== selectionDefinition) {
          for (const kind of ["formula", "cask"]) s.selectedUpgrades[kind] = packages.filter(p => p.kind === kind && p.outdated && !p.pinned).slice(0, 50).map(p => p.name);
          s.selectionDefinition = selectionDefinition;
        } else for (const kind of ["formula", "cask"]) s.selectedUpgrades[kind] = s.selectedUpgrades[kind].filter(name => packages.some(p => p.name === name && p.kind === kind && p.outdated && !p.pinned));
      }
      s.start = 0;
    }
  }
  if (e.type === "load_range") { s.start = e.start; s.count = Math.min(e.count, 100); }
  const cached = readCache("packages-" + s.mode);
  const allPackages = cached && cached.definition === definition ? cached.packages : s.packages;
  if (e.type === "source_delivered" && e.source === "rankings") {
    if (e.failure) s.popularityMessage = e.failure.message;
    else {
      const kind = (s.popularityInput || {}).kind || s.kind, cache = readCache("popularity-" + kind) || {rankings: []};
      const updated = (e.result.rankings || []).map(p => Object.assign({checkedAt: Date.now()}, p));
      const names = updated.map(p => p.name);
      writeCache({key: "popularity-" + kind, value: {rankings: cache.rankings.filter(p => !names.includes(p.name)).concat(updated).slice(-2000)}});
      s.popularityMessage = "";
    }
    s.popularityInput = null;
  }
  const popularity = {};
  for (const kind of ["formula", "cask"]) for (const record of ((readCache("popularity-" + kind) || {}).rankings || [])) {
    const count = (((record.analytics || {}).install || {})["30d"]);
    if (typeof count === "number" && Date.now() - record.checkedAt < 86400000) popularity[kind + ":" + record.name] = count;
  }
  const packages = allPackages.map((p, position) => Object.assign({position}, p)).filter(p => (!s.filter || (p.name + " " + (p.title || "") + " " + (p.description || "")).toLowerCase().includes(s.filter.toLowerCase())) && (s.hideDependencies !== "on" || !p.installed_as_dependency || p.installed_on_request)).sort((a, b) => ((a.pinned ? 0 : 2) + (a.kind === "cask" ? 1 : 0)) - ((b.pinned ? 0 : 2) + (b.kind === "cask" ? 1 : 0)) || (s.sort === "popularity" ? (popularity[b.kind + ":" + b.name] === undefined ? -1 : popularity[b.kind + ":" + b.name]) - (popularity[a.kind + ":" + a.name] === undefined ? -1 : popularity[a.kind + ":" + a.name]) : 0));
  const packageSections = [["pinned-formula", "Pinned Tools", true, "formula"], ["pinned-cask", "Pinned Apps", true, "cask"], ["formula", "Command-line Tools", false, "formula"], ["cask", "Apps", false, "cask"]].map(([id, title, pinned, kind]) => c.section({id, title, count: packages.filter(p => !!p.pinned === pinned && p.kind === kind).length})).filter(section => section.count);
  if (e.type === "action_chosen" && e.action === "rank-packages" && s.kind !== "both") {
    const selected = packages.slice(s.start || 0).filter(p => p.kind === s.kind && /^[a-z0-9][a-z0-9+_.@-]{0,63}$/.test(p.name) && popularity[p.kind + ":" + p.name] === undefined).slice(0, 20).map(p => p.name);
    s.popularityInput = selected.length ? {tool: "homebrew", operation: "packageAnalytics", kind: s.kind, names: selected} : null;
    s.popularityMessage = selected.length ? "Reading popularity for " + selected.length + " selected packages…" : "This window has no unranked official packages.";
  }
  const start = Math.min(s.start || 0, Math.max(0, packages.length - 1));
  const items = packages.slice(start, start + (s.count || 80));
  const content = [
    homeNavigation(),
    c.choiceField({id: "browse", title: "Packages", choices: ["installed", "outdated", "search"], choiceTitles: ["Installed", "Updates", "Find Packages"], value: s.mode}),
    c.choiceField({id: "kind", title: "Show", choices: ["both", "formula", "cask"], choiceTitles: ["All Packages", "Command-line Tools", "Apps"], value: s.kind})
  ];
  if (s.mode === "search") content.push(c.textField({id: "query", title: "Search Packages", placeholder: "Package name, e.g. wget", value: s.query, collection: "packages"}));
  else content.push(c.textField({id: "filter", title: "Filter Packages", placeholder: "Name or description", value: s.filter || "", collection: "packages"}));
  if (s.filterOptions && s.mode === "installed") content.push(c.choiceField({id: "hideDependencies", title: "Include Dependencies", choices: ["off", "on"], choiceTitles: ["All Installed Packages", "Requested Packages Only"], value: s.hideDependencies || "off"}));
  if (s.mode === "outdated" && s.kind !== "formula") content.push(c.choiceField({id: "greedy", title: "Self-updating Apps", choices: ["off", "on"], choiceTitles: ["Exclude", "Include"], value: s.greedy}));
  if (s.filterOptions) content.push(c.choiceField({id: "sort", title: "Order Within Groups", choices: ["catalogue", "popularity"], choiceTitles: ["Catalogue Order", "Known 30-Day Popularity"], value: s.sort || "catalogue"}));
  if (s.sort === "popularity") {
    const known = packages.filter(p => popularity[p.kind + ":" + p.name] !== undefined).length;
    content.push(c.text({id: "popularity-coverage", text: known + " of " + packages.length + " visible matches have known popularity from the last day. Other counts are unknown and sort after known counts. Each explicit request ranks at most 20 packages; no catalogue sweep runs."}));
    if (s.kind !== "both") content.push(c.actions({id: "popularity-window", actions: [c.button({id: "rank-packages", title: "Rank Next 20 Packages in This Window"})]}));
    else content.push(c.text({id: "popularity-kind", text: "Choose Tools or Apps to request a popularity window."}));
    if (s.popularityMessage) content.push(c.text({id: "popularity-read-status", text: s.popularityMessage}));
  }
  content.push(c.actions({id: "refresh-controls", actions: [c.button({id: "check-updates", title: "Update Homebrew Catalog…"}), c.button({id: "refresh", title: "Refresh List"}), c.button({id: "filter-options", title: s.filterOptions ? "Hide Filter Options" : "Filter Options…"})]}));
  content.push(c.text({id: "hint", text: s.message || (s.loading ? "Loading packages…" : s.mode === "search" && !validQuery ? "Type at least two lowercase letters or numbers to find packages." : s.truncated ? "Showing " + allPackages.length + " bounded results. Narrow the search or filter to see more." : "Choose a package to see details.")}));
  if (s.mode === "outdated") {
    content.push(c.text({id: "upgrade-review", text: "Eligible packages start selected, up to 50 per kind. Pinned packages are locked until explicitly unpinned. Selected tools and Apps run as separate confirmed Tasks; Upgrade All resolves every eligible package in the Host."}));
    const buttons = [c.button({id: "preview-upgrade-all", title: "Preview All Eligible Upgrades"}), c.button({id: "upgrade-all", title: "Review All Eligible Upgrades"})];
    for (const kind of ["formula", "cask"]) if (s.selectedUpgrades[kind].length) {
      buttons.push(c.button({id: "preview-selected-" + kind, title: "Preview Selected " + (kind === "formula" ? "Tools" : "Apps")}));
      buttons.push(c.button({id: "upgrade-selected-" + kind, title: "Upgrade " + s.selectedUpgrades[kind].length + (kind === "formula" ? " Selected Tools" : " Selected Apps")}));
    }
    content.push(c.actions({id: "upgrade-controls", actions: buttons}));
  }
  content.push(c.text({id: "package-summary", text: packages.length + " packages" + (s.filter ? " matching this filter" : "") + (s.mode === "outdated" ? " · " + (s.selectedUpgrades.formula.length + s.selectedUpgrades.cask.length) + " selected for upgrade" : ""), style: {color: "secondary"}}));
  if (s.mode === "outdated") content.push(c.text({id: "catalog-help", text: "Update Homebrew Catalog fetches the latest package information. Refresh List checks the current local catalog.", style: {color: "secondary"}}));
  content.push(c.list({id: "packages", total: packages.length, start, sections: packageSections.length ? packageSections : undefined, items: items.map(p => c.item({id: packageID(p), text: p.name, title: p.title || p.name, subtitle: [p.name, p.kind === "cask" ? "App" : "Command-line Tool", p.installed_version ? (p.outdated && p.version ? p.installed_version + " → " + p.version : "Installed " + p.installed_version) : p.version || "", p.pinned ? "Pinned" : p.outdated ? "Update available" : ""].filter(Boolean).join(" · "), marks: s.selectedUpgrades[p.kind].includes(p.name) ? ["upgrade_selected"] : [], actions: p.outdated && !p.pinned ? ["details", "queue-upgrade"] : ["details"]})), emptyText: s.message ? "Could not load packages. See the message above." : s.loading ? "Loading packages…" : s.mode === "search" && !validQuery ? "Enter at least two characters to search." : s.mode === "outdated" && !allPackages.length ? "No updates found for this package selection." : s.filter && !packages.length ? "No matches. Try changing the filter." : "No packages found.", actions: [c.itemAction({id: "details", title: "Show Details", default: true}), c.itemAction({id: "queue-upgrade", title: "Select for Upgrade", toggle: "upgrade_selected"})]}));
  const page = {id: "homebrew-browse-" + s.mode, title: modeTitles[modes.indexOf(s.mode)], resizable: {minHeight: 360}, content};
  if (s.mode !== "search" || validQuery) page.sources = [spinnet.tools.read.source(sourceID("packages"), request, {deliver: true})];
  if (s.popularityInput) page.sources = (page.sources || []).concat([spinnet.tools.read.source("rankings", s.popularityInput, {deliver: true})]);
  page.sources = watching(page.sources);
  return spinnet.ui.showPage(spinnet.ui.page(page), {state: s, operation});
})()
