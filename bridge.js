"use strict";

// Local bridge for Terminal Notification 0.1.4; no network requests or telemetry.
function createBridge(options, dependencies = {}) {
  const fs = dependencies.fs || require("node:fs");
  const path = dependencies.path || require("node:path");
  const process = dependencies.process || globalThis.process;
  const spawn = dependencies.spawn || require("node:child_process").spawn;
  const vscode = options.vscode;
  const idToTerminal = options.terminals;
  const stateDirectory = options.stateDirectory || process.env.CODEX_NOTIFY_STATE_DIR ||
    path.join(process.env.LOCALAPPDATA || path.join(require("node:os").homedir(), "AppData", "Local"), "CodexDesktopNotify");
function codexCompletionPreview(response) {
  const normalized = String(response || "").replace(/\p{White_Space}+/gu, " ").trim();
  if (!normalized) return "Agent turn complete";
  const graphemes = Array.from(new Intl.Segmenter("en", {granularity: "grapheme"}).segment(normalized), (part) => part.segment);
  return graphemes.length > 200 ? graphemes.slice(0, 197).join("") + "..." : normalized;
}
function completionRoutingLog(event) {
  if (process.env.CODEX_NOTIFY_DEBUG !== "1") return;
  try {
    fs.mkdirSync(stateDirectory, {recursive: true});
    fs.appendFileSync(path.join(stateDirectory, "events.jsonl"),
      JSON.stringify({time: new Date().toISOString(), event}) + "\n");
  } catch {}
}
function safeNotification(title, message) {
  if (process.env.CODEX_NOTIFY_PREVIEW !== "0") return {title, message};
  return {title: "Terminal", message: "终端有新通知，请返回查看。"};
}
function routeCodexCompletion(tid, message) {
  if (process.platform !== "win32") return false;
  const directory = path.join(stateDirectory, "completion");
  try {
    if (!fs.existsSync(directory)) return false;
    const pending = [];
    let matchingRecords = 0;
    let alreadyRouted = false;
    for (const name of fs.readdirSync(directory)) {
      if (!/^[0-9a-f-]{36}\.json$/.test(name)) continue;
      const filename = path.join(directory, name);
      let record;
      try { record = JSON.parse(fs.readFileSync(filename, "utf8")); } catch { continue; }
      const age = Date.now() - record.created_ms;
      if (age < 0 || age > 40000 || name !== record.token + ".json" || !record.session_id) continue;
      if (codexCompletionPreview(record.response) !== message) continue;
      matchingRecords++;
      const routePath = path.join(directory, record.token + ".route.json");
      if (fs.existsSync(routePath)) {
        try { alreadyRouted ||= JSON.parse(fs.readFileSync(routePath, "utf8")).terminal_id === tid; } catch {}
      } else {
        pending.push({record, routePath});
      }
    }
    if (pending.length === 0) return alreadyRouted;
    // Routed records also matter: a repeated older preview must never claim
    // a newer same-text completion belonging to another terminal.
    if (matchingRecords !== 1) {
      completionRoutingLog("completion_ambiguous", {terminal_id: tid, candidates: pending.length});
      return true;
    }
    const term = idToTerminal.get(tid);
    if (!term) return false;
    const {record, routePath} = pending[0];
    const route = {
      session_id: record.session_id,
      terminal_id: tid,
      terminal_name: term.name || "Terminal",
      focus_uri: `${vscode.env.uriScheme}://${options.getContext().extension.id}/focus?tid=${encodeURIComponent(tid)}`
    };
    // Exclusive creation prevents another window from overwriting this route.
    try { fs.writeFileSync(routePath, JSON.stringify(route), {encoding: "utf8", flag: "wx"}); }
    catch (error) {
      if (error.code !== "EEXIST") throw error;
      const winner = JSON.parse(fs.readFileSync(routePath, "utf8"));
      return winner.session_id === record.session_id && winner.terminal_id === tid;
    }
    completionRoutingLog("completion_routed", {session_id: record.session_id, terminal_id: tid});
    return true;
  } catch (error) {
    completionRoutingLog("completion_route_error", {error: String(error)});
    return false;
  }
}
function sendCodexQuestionPopup(tid, title, message) {
  if (process.platform !== "win32" ||
      !/^(Question:|Plan mode prompt:|Approval requested[: ]|Codex wants to edit )/.test(message || "")) return false;
  const popupScript = options.popupScript || path.join(stateDirectory, "notify-done.ps1");
  if (!fs.existsSync(popupScript)) return false;
  const scheme = vscode.env.uriScheme;
  const focusUri = `${scheme}://${options.getContext().extension.id}/focus?tid=${encodeURIComponent(tid)}`;
  const term = idToTerminal.get(tid);
  const payload = JSON.stringify({
    notification_message: message,
    terminal_name: term?.name || "Terminal",
    focus_uri: focusUri
  });
  const fallback = (error) => {
    console.error("Codex question popup failed", error);
    options.getNotifier().notify({...safeNotification(title || "Codex", message), wait: true, tid});
  };
  try {
    const powershell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    const child = spawn(powershell, [
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
      "-File", popupScript, "codex-ask"
    ], {windowsHide: true, stdio: ["pipe", "ignore", "ignore"]});
    let failed = false;
    const reportFailure = (error) => {
      if (failed) return;
      failed = true;
      fallback(error);
    };
    child.once("error", reportFailure);
    child.once("close", (code) => {
      if (code !== 0) reportFailure(`PowerShell exit code ${code}`);
    });
    child.stdin.on("error", reportFailure);
    child.stdin.end(payload, "utf8");
    return true;
  } catch (error) {
    console.error("Could not start Codex question popup", error);
    return false;
  }
}
  return {routeCompletion: routeCodexCompletion, sendQuestion: sendCodexQuestionPopup,
    safeNotification, log: completionRoutingLog};
}
module.exports = {createBridge};
