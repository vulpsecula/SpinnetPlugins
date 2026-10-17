const entryMode = "tap";
const entryCommand = "brew.taps";
(() => {
  const c = spinnet.ui.components;
  const names = ["list","outdated","search","info","update","upgrade","install","uninstall","adopt","services","tap","untap","doctor","cleanup","autoremove","config","version"];
  const titles = ["Installed","Updates","Search","Package Info","Update Catalog","Upgrade","Install","Uninstall","Adopt App","Services","Taps","Remove Tap","Doctor","Clean Up","Autoremove","Configuration","Version"];
  const e = event || {}, initial = typeof input === "object" && input || {};
  const mode = names.includes(entryMode) ? entryMode : "list";
  const s = Object.assign({command:mode,package:initial.package || "",kind:"both",serviceAction:"list",serial:0,output:"",message:"",read:null,readPurpose:"",taskID:null,taskRunning:false,waitingTask:false,admitted:false,seenTasks:[],adoption:null,lastCommand:"",truncated:false,result:null,display:"results",filter:""}, state || {});
  // Interpret only complete, successful native reads. Unknown formats, diagnostics and
  // Task transcripts stay literal; changing the next command never relabels old output.
  function presentation() {
    if (!s.result || s.result.exit !== 0 || s.truncated) return null;
    const command = s.result.command, lines = s.output.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
    const rows = [], token = /^(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*$/;
    let kind = s.result.kind || "both";
    function add(title, subtitle, accessory, icon, name) {
      if (title.length > 256 || (subtitle || "").length > 256 || (accessory || "").length > 64) return false;
      rows.push({id:"result-" + rows.length,title,subtitle:subtitle || "",accessory:accessory || "",icon:{symbol:icon},name,kind});
      return rows.length <= 2000;
    }
    if (["list","outdated","search"].includes(command)) {
      for (const line of lines) {
        if (line === "==> Formulae" || line === "==> Casks") { kind = line === "==> Casks" ? "cask" : "formula"; continue; }
        const version = command === "outdated" && line.match(/^(\S+) \((.+)\) < (.+)$/);
        if (version) {
          if (!token.test(version[1]) || !add(version[1],version[2] + " → " + version[3],"Update","arrow.up.circle",version[1])) return null;
        } else {
          const words = line.split(/\s+/);
          for (let i = 0; i < words.length; i++) {
            const name = words[i].replace(/✔$/, ""), installed = words[i].endsWith("✔") || words[i + 1] === "✔";
            if (words[i + 1] === "✔") i++;
            if (!token.test(name) || !add(name,kind === "cask" ? "Cask App" : kind === "formula" ? "Formula" : "",installed ? "Installed" : command === "outdated" ? "Update" : "",kind === "cask" ? "app" : "shippingbox",name)) return null;
          }
        }
      }
      return {rows,packages:true,empty:command === "outdated" ? "All packages are up to date." : command === "search" ? "No matching packages." : "No installed packages."};
    }
    if (command === "tap" && !s.result.package) {
      for (const line of lines) if (!/^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*$/.test(line) || !add(line,"Tap","","externaldrive")) return null;
      return {rows,empty:"No additional taps."};
    }
    if (command === "config" && lines.length) {
      for (const line of lines) {
        const pair = line.match(/^([A-Za-z0-9][A-Za-z0-9 _().\/-]{0,79}):\s*(.*)$/);
        if (!pair || !add(pair[1],pair[2],"","gearshape")) return null;
      }
      return {rows,empty:"No configuration values."};
    }
    if (command === "services" && s.result.action === "list") {
      if (!lines.length) return {rows,empty:"No Homebrew services."};
      if (!/^Name\s+Status\s+User\s+File$/.test(lines.shift())) return null;
      for (const line of lines) {
        const service = line.match(/^(\S+)\s+(started|stopped|none|scheduled|error(?:\s+\d+)?)(?:\s+(\S+)(?:\s+(.+))?)?$/);
        if (!service || !token.test(service[1]) || !add(service[1],[service[3],service[4]].filter(Boolean).join(" · "),service[2],"server.rack")) return null;
      }
      return {rows,empty:"No Homebrew services."};
    }
    return null;
  }
  const reset = [];
  const busy = s.read || s.taskRunning || s.waitingTask;
  if (e.type === "called" && !busy) Object.assign(s,{command:mode,package:initial.package || "",message:"",adoption:null});
  if (!busy) for (const key of ["command","package","kind","serviceAction"]) if (e.values && typeof e.values[key] === "string" && s[key] !== e.values[key]) { s[key] = e.values[key]; s.adoption = null; }
  if (e.values && ["results","raw"].includes(e.values.display)) s.display = e.values.display;
  const filterValue = e.values && e.values["filter-" + s.serial];
  if (typeof filterValue === "string" && s.filter !== filterValue) { s.filter = filterValue.slice(0,256); reset.push("results-" + s.serial); }
  let inspect = false;
  if (!busy && e.type === "item_action" && e.collection === "results-" + s.serial && e.action === "package-info" && s.display === "results") {
    const parsed = presentation(), row = parsed && parsed.packages && parsed.rows.find(row => e.item && row.id === e.item.id);
    if (row) { s.command = "info"; s.package = row.name; s.kind = row.kind; s.adoption = null; inspect = true; reset.push("command","package","kind"); }
  }
  if (!names.includes(s.command)) s.command = "list";
  const packageCommands = ["list","outdated","search","info","upgrade","install","uninstall"];
  const hasPackage = packageCommands.includes(s.command) || ["adopt","services","tap","untap"].includes(s.command);
  const needsPackage = ["install","uninstall","search","info","adopt","untap"].includes(s.command) || (s.command === "services" && s.serviceAction !== "list");
  const packageText = String(s.package || "").trim(), argument = {command:s.command};
  if (packageCommands.includes(s.command) && ["formula","cask"].includes(s.kind)) argument.kind = s.kind;
  if (s.command === "services") argument.action = ["list","start","stop","restart","info"].includes(s.serviceAction) ? s.serviceAction : "list";
  if (hasPackage && packageText && (s.command !== "services" || argument.action !== "list")) argument.package = packageText;
  let problem = needsPackage && !packageText ? "Enter " + (s.command === "search" ? "search text." : s.command === "untap" ? "a tap in owner/repository form." : "a package name.") : "";
  if (argument.package && (packageText.length > 160 || /[\x00-\x1f\x7f]/.test(packageText))) problem = "Use up to 160 characters without control characters.";
  if (argument.package && s.command !== "search" && !(["tap","untap"].includes(s.command) ? /^[a-z0-9][a-z0-9_.-]{0,63}\/[a-z0-9][a-z0-9_.-]{0,63}$/ : /^(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*$/).test(packageText)) problem = "Enter one package name or owner/repository/package, without shell options.";
  if ((["install","uninstall"].includes(s.command) || (s.command === "upgrade" && packageText)) && !argument.kind) problem = "Select Formula or Cask App for this package operation.";
  const argv = [s.command === "version" ? "--version" : s.command];
  if (argument.kind) argv.push("--" + argument.kind);
  if (s.command === "services") argv.push(argument.action);
  if (s.command === "adopt") argv.splice(0,argv.length,"install","--cask","--adopt");
  if (s.command === "cleanup") argv.push("--prune=120");
  if (argument.package) argv.push("--",argument.package);
  const quote = value => /^[a-zA-Z0-9_./@+=-]+$/.test(value) ? value : "'" + value.replace(/'/g,"'\\''") + "'";
  const preview = ["brew"].concat(argv).map(quote).join(" ");
  function showOutput(value,truncated) {
    const text = typeof value === "string" ? value : "";
    // Keep even non-ASCII transcripts below the published 64 KiB state budget.
    s.output = text.slice(-12000);
    if (s.output.charCodeAt(0) >= 0xdc00 && s.output.charCodeAt(0) <= 0xdfff) s.output = s.output.slice(1);
    s.truncated = !!truncated || text.length > 12000;
  }
  function read(input,purpose) { s.read = {id:"command-read-" + (++s.serial),input}; s.readPurpose = purpose; }
  let operation;
  if (((e.type === "action_chosen" && e.action === "run-command") || inspect) && !problem && !busy) {
    s.lastCommand = preview; s.message = "Running…"; showOutput("",false);
    s.result = null; s.filter = ""; s.display = "results";
    reset.push("display");
    const readonly = ["list","outdated","search","info","doctor","config","version"].includes(s.command) || (s.command === "tap" && !packageText) || (s.command === "services" && ["list","info"].includes(argument.action));
    if (readonly) read(Object.assign({tool:"homebrew",operation:"commandOutput"},argument),"command");
    else if (s.command === "adopt" && !(s.adoption && s.adoption.package === packageText && s.adoption.target)) read({tool:"homebrew",operation:"adoptionCandidates"},"adoption-candidates");
    else {
      const task = {tool:"homebrew",operation:s.command};
      if (["install","uninstall"].includes(s.command) || (s.command === "upgrade" && packageText)) { task.kind = argument.kind; task.name = packageText; }
      if (s.command === "upgrade" && !packageText) { task.operation = "upgradeAll"; if (argument.kind) task.kind = argument.kind; }
      if (["tap","untap"].includes(s.command)) task.tap = packageText;
      if (s.command === "services") { task.operation = "service" + argument.action[0].toUpperCase() + argument.action.slice(1); task.name = packageText; }
      if (s.command === "adopt") task.target = s.adoption.target;
      s.seenTasks = (spinnet.activities.list() || []).map(item => item.id);
      s.taskID = null; s.waitingTask = true; s.admitted = false; s.taskRunning = false;
      operation = spinnet.tools.startTask.operation(task,{id:"command-task",notify:true});
      s.message = "Waiting for Homebrew confirmation…";
    }
  }
  if (e.type === "source_delivered" && s.read && e.source === s.read.id) {
    const purpose = s.readPurpose; s.read = null; s.readPurpose = "";
    if (e.failure) { s.message = e.failure.message || "The command could not be read."; showOutput(s.message,false); }
    else {
      const result = e.result || {};
      if (purpose === "command") {
        showOutput(result.output,result.output_truncated);
        s.result = Object.assign({},argument,{exit:result.exit_status});
        s.message = result.exit_status === 0 ? "Completed · " + s.lastCommand : "Exited with status " + result.exit_status + " · " + s.lastCommand;
      }
      else if (purpose === "adoption-candidates") {
        const matches = (result.applications || []).filter(app => (app.candidates || []).some(candidate => candidate.name === packageText && ["ready","likely"].includes(candidate.confidence)));
        if (matches.length !== 1) s.message = "No unique installed App matches this cask. Verify its cask name before adopting.";
        else { s.message = "Reading the native adoption preview…"; read({tool:"homebrew",operation:"adoptionPreview",target:matches[0].target,name:packageText},"adoption-preview"); }
      } else if (purpose === "adoption-preview") {
        showOutput((result.stdout || "") + (result.stderr ? "\n" + result.stderr : ""),false);
        s.adoption = result.succeeded && result.target ? {package:packageText,target:result.target} : null;
        s.message = s.adoption ? "Preview ready. Run again to review and confirm adoption." : "Adoption preview did not complete; no changes were made.";
      }
    }
  }
  if (e.type === "operation_finished" && e.operation === "command-task") {
    s.waitingTask = e.outcome === "succeeded"; s.admitted = s.waitingTask;
    s.message = s.waitingTask ? "Waiting for command output…" : "Command did not start" + (e.reason ? ": " + e.reason : " (" + e.outcome + ")");
  }
  if (e.type === "source_delivered" && e.source === "command-tasks") {
    if (e.failure) s.message = e.failure.message || "Command status is temporarily unavailable.";
    else {
      const tasks = Array.isArray(e.result) ? e.result : [];
      const task = s.taskID ? tasks.find(item => item.id === s.taskID) : s.waitingTask && s.admitted ? tasks.find(item => item.kind === "task" && item.tool === "homebrew" && !s.seenTasks.includes(item.id)) : null;
      if (task) {
        s.taskID = task.id; s.waitingTask = false; s.taskRunning = task.status !== "ended";
        showOutput(typeof task.output === "string" ? task.output : (task.log || []).join("\n"),task.output_truncated);
        const outcome = task.result || {};
        s.message = s.taskRunning ? (task.status === "stopping" ? "Stopping…" : "Running…") : "Command " + (outcome.outcome || "ended") + (outcome.reason ? ": " + outcome.reason : "") + (typeof outcome.exit_status === "number" ? " (exit " + outcome.exit_status + ")" : "");
      }
    }
  }
  if (e.type === "action_chosen" && e.action === "stop-command" && s.taskID && s.taskRunning) operation = spinnet.activities.stop.operation({id:s.taskID},{id:"stop-command",notify:true});
  if (e.type === "action_chosen" && e.action === "cancel-read" && s.read) { s.read = null; s.message = "Read cancelled."; }
  const running = s.read || s.taskRunning || s.waitingTask, content = [];
  if (!running) {
    const controls = [c.choiceField({id:"command",title:"Command",choices:names,choiceTitles:titles,value:s.command})];
    if (packageCommands.includes(s.command)) controls.push(c.choiceField({id:"kind",title:"Packages",choices:["both","formula","cask"],choiceTitles:["All","Formulae","Cask Apps"],value:s.kind}));
    if (s.command === "services") controls.push(c.choiceField({id:"serviceAction",title:"Action",choices:["list","start","stop","restart","info"],value:argument.action}));
    if (!problem) controls.push(c.actions({id:"execute",actions:[c.button({id:"run-command",title:s.adoption && s.command === "adopt" ? "Confirm Adoption…" : s.command === "search" ? "Search" : ["list","outdated","config","services","tap"].includes(s.command) ? "Refresh" : "Run"})]}));
    content.push(c.row({id:"command-bar",content:controls}));
    if (hasPackage && (s.command !== "services" || argument.action !== "list")) content.push(c.textField({id:"package",title:s.command === "search" ? "Search Text" : ["tap","untap"].includes(s.command) ? "Tap (optional for listing)" : "Package" + (needsPackage ? "" : " (optional)"),value:s.package,placeholder:["tap","untap"].includes(s.command) ? "owner/repository" : "e.g. wget or firefox"}));
    content.push(c.text({id:"command-preview",text:"`" + preview.replace(/`/g,"ˋ") + "`",style:{color:"secondary",fontSize:11}}));
    if (problem) content.push(c.text({id:"input-help",text:problem}));
  } else content.push(c.text({id:"command-preview",text:"`" + s.lastCommand.replace(/`/g,"ˋ") + "`",style:{color:"secondary",fontSize:11}}));
  if (s.message) content.push(c.text({id:"command-status",text:s.message.replace(/([\\`*_{}\[\]<>])/g,"\\$1"),style:{color:"secondary",fontSize:11}}));
  const parsed = presentation(), collectionID = "results-" + s.serial;
  if (parsed) content.push(c.choiceField({id:"display",title:"View",choices:["results","raw"],choiceTitles:["Results","Raw Output"],value:s.display}));
  if (parsed && s.display !== "raw") {
    const query = s.filter.trim().toLowerCase(), rows = parsed.rows.filter(row => [row.title,row.subtitle,row.accessory].join(" ").toLowerCase().includes(query));
    content.push(c.row({id:"results-bar",content:[c.textField({id:"filter-" + s.serial,title:"Filter",value:s.filter,placeholder:"Filter results…",collection:collectionID}),c.text({id:"result-count",text:rows.length + (query ? " of " + parsed.rows.length : "") + " results",style:{color:"secondary",fontSize:11}})]}));
    // Paging bounds answer size while preserving stable row IDs and scroll position.
    const start = e.type === "load_range" && e.collection === collectionID ? Math.max(0,Math.min(rows.length,Math.floor(e.start || 0))) : 0;
    const count = e.type === "load_range" ? Math.max(1,Math.min(600,Math.floor(e.count || 80))) : 80;
    content.push(c.list({id:collectionID,rows:10,total:rows.length,start,items:rows.slice(start,start + count).map(row => c.item({id:row.id,title:row.title,subtitle:row.subtitle,accessory:row.accessory,icon:row.icon})),emptyText:query ? "No results match this filter." : parsed.empty,actions:parsed.packages ? [c.itemAction({id:"package-info",title:"Package Info",default:true})] : undefined}));
  } else if (!s.lastCommand && !running) content.push(c.column({id:"command-empty",style:{padding:16},content:[c.icon({id:"empty-icon",source:{symbol:"shippingbox"},size:32}),c.text({id:"empty-title",text:titles[names.indexOf(s.command)],style:{fontSize:20,fontWeight:"semibold"}}),c.text({id:"empty-help",text:"Choose your options above, then run the command to load its results.",style:{color:"secondary"}})]}));
  else content.push(c.text({id:"command-output",title:"Output",text:s.output || (running ? "Waiting for output…" : "No output."),format:"output"}));
  if (s.truncated) content.push(c.text({id:"output-limit",text:"Showing the latest output; earlier text exceeded the display limit.",style:{color:"secondary"}}));
  if (s.taskRunning) content.push(c.actions({id:"stop",actions:[c.button({id:"stop-command",title:"Stop"})]}));
  if (s.read) content.push(c.actions({id:"cancel",actions:[c.button({id:"cancel-read",title:"Cancel"})]}));
  const legacy = entryMode === "legacy-security" ? "Security Check is no longer provided by this command launcher." : entryMode === "legacy-cache" ? "This command launcher does not cache package information. Previous Plugin data has been retained." : "";
  if (legacy) content.push(c.text({id:"legacy-command",text:legacy,style:{color:"secondary"}}));
  const sources = [];
  if (s.read) sources.push(spinnet.tools.read.source(s.read.id,s.read.input,{deliver:true}));
  if (s.taskRunning || s.waitingTask) sources.push(spinnet.activities.list.source("command-tasks",{every:1,deliver:true}));
  const page = {id:"homebrew-command",title:"Homebrew",resizable:{minWidth:720,minHeight:400},content};
  const componentIDs = [];
  function collect(components) { for (const component of components) { componentIDs.push(component.id); if (component.content) collect(component.content); } }
  collect(content);
  if (reset.some(id => componentIDs.includes(id))) page.reset = reset.filter(id => componentIDs.includes(id));
  if (sources.length) page.sources = sources;
  return spinnet.ui.showPage(spinnet.ui.page(page),{state:s,operation});
})()
