// SPDX-License-Identifier: MIT
// Presentation policy for Host-projected Homebrew objects. No process or I/O.
const brewCatalog = (() => {
  const sections = ["list","search","outdated","update","adopt","services","tap","doctor","cleanup"];
  const titles = ["Installed","Search","Available Upgrades","Update Catalog","Adopt Apps","Services","Taps","Doctor","Clean Up"];
  const key = item => item.kind + ":" + item.name;
  function id(value) {
    let a = 2166136261, b = 5381;
    for (let i = 0; i < value.length; i++) { a = Math.imul(a ^ value.charCodeAt(i),16777619); b = Math.imul(b,33) ^ value.charCodeAt(i); }
    return "row-" + (a >>> 0).toString(16) + "-" + (b >>> 0).toString(16);
  }
  const text = value => String(value == null ? "" : value).replace(/([\\`*_{}\[\]<>])/g,"\\$1");
  const queryValid = value => /^[a-z0-9+_.@][a-z0-9+_.@-]{1,63}$/.test(value);
  const tapValid = value => /^[a-z0-9][a-z0-9_.-]{0,63}\/[a-z0-9][a-z0-9_.-]{0,63}$/.test(value);
  function packages(result, inventory) {
    const installed = new Map((inventory && inventory.packages || []).map(item => [key(item),item]));
    const complete = !!inventory && !inventory.truncated;
    return (result && result.packages || []).map(item => {
      const previous = result.operation === "search" ? installed.get(key(item)) : null;
      const merged = Object.assign({},previous || {},item);
      merged.isInstalled = !!previous || !!item.installed_version || result.operation === "installed" || result.operation === "outdated";
      merged.installationKnown = merged.isInstalled || complete;
      if (result.operation === "outdated") merged.outdated = true;
      return merged;
    });
  }
  function primary(item) {
    if (!item.installationKnown || item.disabled || (item.isInstalled && item.pinned)) return "details";
    if (!item.isInstalled) return "install";
    return item.outdated ? "upgrade" : "details";
  }
  function actions(item) {
    const result = ["activate","details"];
    if (item.isInstalled) result.push("uninstall",item.pinned ? "unpin" : "pin");
    if (primary(item) === "install" || primary(item) === "upgrade") result.push("preview");
    return [...new Set(result)];
  }
  function group(item, screen) {
    if (screen === "outdated" || screen === "upgrade") return item.pinned ? "Pinned" : item.kind === "cask" ? "Cask Apps" : "Formulae";
    if (item.pinned) return item.kind === "cask" ? "Pinned Cask Apps" : "Pinned Formulae";
    if (item.kind === "cask") return "Cask Apps";
    return item.installed_as_dependency && !item.installed_on_request ? "Dependencies" : "Formulae";
  }
  function grouped(items, groupOf) {
    const groups = new Map();
    for (const item of items) { const name = groupOf(item); if (!groups.has(name)) groups.set(name,[]); groups.get(name).push(item); }
    const order = ["Running","Stopped","Ready to Adopt","Likely Adoptable","Unlikely Adoptions","Cannot Adopt","Pinned Cask Apps","Pinned Formulae","Cask Apps","Formulae","Dependencies","Pinned"];
    return [...groups].map(([title,items]) => ({id:id(title),title,items})).sort((a,b) => order.indexOf(a.title) - order.indexOf(b.title));
  }
  function byteLength(value) {
    const string = JSON.stringify(value);
    let size = 0;
    for (const character of string) { const point = character.codePointAt(0); size += point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4; }
    return size;
  }
  // A read result fits the wire budget, but the cache envelope also costs bytes.
  function bounded(result) {
    const copy = JSON.parse(JSON.stringify(result));
    if (byteLength(copy) <= 480 * 1024) return copy;
    for (const field of ["packages","applications","taps"]) if (Array.isArray(copy[field])) {
      while (copy[field].length && byteLength(copy) > 480 * 1024) copy[field].pop();
      copy.truncated = true;
    }
    return copy;
  }
  return {sections,titles,key,id,text,queryValid,tapValid,packages,primary,actions,group,grouped,byteLength,bounded};
})();
