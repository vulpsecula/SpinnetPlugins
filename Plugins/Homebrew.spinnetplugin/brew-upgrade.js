const entryMode = "upgrade";
const entryCommand = "brew.upgrade";
(() => {
  const c = spinnet.ui.components;
  const names = ["list","outdated","search","info","update","upgrade","install","uninstall","adopt","services","tap","untap","doctor","cleanup","autoremove","config","version"];
  const titles = ["List Installed Packages","List Available Updates","Search Packages","Package Info","Update Homebrew Catalog","Upgrade Packages","Install Package","Uninstall Package","Adopt an Existing App","Services","List or Add Taps","Remove Tap","Doctor","Clean Up","Remove Unused Dependencies","Configuration","Version"];
  const e = event || {}, initial = typeof input === "object" && input || {};
  const mode = names.includes(entryMode) ? entryMode : "list";
  const s = Object.assign({command:mode,package:initial.package || "",kind:"both",serviceAction:"list",serial:0,output:"",message:"",read:null,readPurpose:"",taskID:null,taskRunning:false,waitingTask:false,admitted:false,seenTasks:[],adoption:null,lastCommand:"",truncated:false}, state || {});
  const busy = s.read || s.taskRunning || s.waitingTask;
  if (e.type === "called" && !busy) Object.assign(s,{command:mode,package:initial.package || "",message:"",adoption:null});
  if (!busy) for (const key of ["command","package","kind","serviceAction"]) if (e.values && typeof e.values[key] === "string" && s[key] !== e.values[key]) { s[key] = e.values[key]; s.adoption = null; }
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
  if (e.type === "action_chosen" && e.action === "run-command" && !problem && !busy) {
    s.lastCommand = preview; s.message = "Running…"; showOutput("",false);
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
      if (purpose === "command") { showOutput(result.output,result.output_truncated); s.message = "Exited with status " + result.exit_status + "."; }
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
    content.push(c.choiceField({id:"command",title:"Homebrew Command",choices:names,choiceTitles:titles,value:s.command}));
    if (packageCommands.includes(s.command)) content.push(c.choiceField({id:"kind",title:"Package Type",choices:["both","formula","cask"],choiceTitles:["Default","Formula","Cask App"],value:s.kind}));
    if (s.command === "services") content.push(c.choiceField({id:"serviceAction",title:"Service Action",choices:["list","start","stop","restart","info"],value:argument.action}));
    if (hasPackage && (s.command !== "services" || argument.action !== "list")) content.push(c.textField({id:"package",title:s.command === "search" ? "Search Text" : ["tap","untap"].includes(s.command) ? "Tap (optional for listing)" : "Package" + (needsPackage ? "" : " (optional)"),value:s.package,placeholder:["tap","untap"].includes(s.command) ? "owner/repository" : "e.g. wget or firefox"}));
    content.push(c.text({id:"command-preview",title:"Command",text:preview,format:"output"}));
    if (problem) content.push(c.text({id:"input-help",text:problem}));
    else content.push(c.actions({id:"execute",actions:[c.button({id:"run-command",title:s.adoption && s.command === "adopt" ? "Confirm Adoption…" : "Run"})]}));
  } else content.push(c.text({id:"command-preview",title:"Command",text:s.lastCommand,format:"output"}));
  if (s.message) content.push(c.text({id:"command-status",text:s.message}));
  content.push(c.text({id:"command-output",title:"Output",text:s.output || (running ? "Waiting for output…" : "Run a command to see its output here."),format:"output"}));
  if (s.truncated) content.push(c.text({id:"output-limit",text:"Showing the latest output; earlier text exceeded the display limit.",style:{color:"secondary"}}));
  if (s.taskRunning) content.push(c.actions({id:"stop",actions:[c.button({id:"stop-command",title:"Stop"})]}));
  if (s.read) content.push(c.actions({id:"cancel",actions:[c.button({id:"cancel-read",title:"Cancel"})]}));
  const legacy = entryMode === "legacy-security" ? "Security Check is no longer provided by this command launcher." : entryMode === "legacy-cache" ? "This command launcher does not cache package information. Previous Plugin data has been retained." : "";
  if (legacy) content.push(c.text({id:"legacy-command",text:legacy,style:{color:"secondary"}}));
  const sources = [];
  if (s.read) sources.push(spinnet.tools.read.source(s.read.id,s.read.input,{deliver:true}));
  if (s.taskRunning || s.waitingTask) sources.push(spinnet.activities.list.source("command-tasks",{every:1,deliver:true}));
  const page = {id:"homebrew-command",title:"Homebrew",resizable:{minWidth:720,minHeight:400},content};
  if (sources.length) page.sources = sources;
  return spinnet.ui.showPage(spinnet.ui.page(page),{state:s,operation});
})()
