"use strict";
const assert = require("node:assert/strict");
const {test} = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {EventEmitter} = require("node:events");
const {createBridge} = require("../bridge.js");

function setup(t, overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "notify-test-"));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const script = path.join(root, "notify-done.ps1");
  fs.writeFileSync(script, "# Synthetic test script; not executed\n");
  const child = new EventEmitter();
  child.stdin = new EventEmitter();
  const calls = {spawn: [], notify: [], payload: []};
  child.stdin.end = (data, encoding) => calls.payload.push({data: JSON.parse(data), encoding});
  const options = {vscode: {env: {uriScheme: "vscode"}},
    terminals: new Map([["test terminal", {name: "示例终端"}]]),
    getContext: () => ({extension: {id: "wenbopan.vscode-terminal-osc-notifier"}}),
    getNotifier: () => ({notify: data => calls.notify.push(data)}), stateDirectory: root, popupScript: script};
  const dependencies = {process: {platform: "win32", env: {}},
    spawn: (...args) => {calls.spawn.push(args); return child;}, ...overrides};
  const bridge = createBridge(options, dependencies);
  return {root, script, child, calls, options, dependencies, bridge};
}

const token = "11111111-1111-4111-8111-111111111111";
function pending(root, extra = {}) {
  const directory = path.join(root, "completion");
  fs.mkdirSync(directory, {recursive: true});
  const record = {token, session_id: "synthetic-session", response: "测试完成。", created_ms: Date.now(), ...extra};
  fs.writeFileSync(path.join(directory, record.token + ".json"), JSON.stringify(record));
  return path.join(directory, record.token + ".route.json");
}

for (const message of ["Question: 请确认示例选项？", "Plan mode prompt: choose", "Approval requested: command", "Codex wants to edit example.txt"]) {
  test(`question format: ${message.split(":")[0]}`, t => {
    const {bridge, calls, script} = setup(t);
    assert.equal(bridge.sendQuestion("test terminal", "Codex", message), true);
    assert.equal(calls.spawn[0][1].at(-2), script);
    assert.equal(calls.spawn[0][1].at(-1), "codex-ask");
    assert.equal(calls.spawn[0][2].windowsHide, true);
    assert.equal(calls.payload[0].encoding, "utf8");
    assert.equal(calls.payload[0].data.notification_message, message);
    assert.equal(calls.payload[0].data.terminal_name, "示例终端");
    assert.equal(calls.payload[0].data.focus_uri,
      "vscode://wenbopan.vscode-terminal-osc-notifier/focus?tid=test%20terminal");
    assert.equal(calls.notify.length, 0);
  });
}

test("ordinary text and non-Windows hosts use upstream fallback", t => {
  const {bridge, calls, options} = setup(t);
  assert.equal(bridge.sendQuestion("test terminal", "Codex", "ordinary output"), false);
  const other = createBridge(options, {process: {platform: "linux", env: {}}});
  assert.equal(other.sendQuestion("test terminal", "Codex", "Question: example"), false);
  assert.equal(other.routeCompletion("test terminal", "test"), false);
  assert.equal(calls.spawn.length, 0);
});

test("missing script or synchronous launch error lets upstream notify", t => {
  const {bridge, script, options} = setup(t);
  fs.unlinkSync(script);
  assert.equal(bridge.sendQuestion("test terminal", "Codex", "Question: example"), false);
  fs.writeFileSync(script, "# example");
  const broken = createBridge(options, {process: {platform: "win32", env: {}}, spawn: () => {throw Error("synthetic spawn failure");}});
  assert.equal(broken.sendQuestion("test terminal", "Codex", "Question: example"), false);
});

for (const event of ["error", "close", "stdin"]) {
  test(`asynchronous ${event} failure falls back once with correct terminal`, t => {
    const {bridge, child, calls} = setup(t);
    bridge.sendQuestion("test terminal", "Codex", "Question: example");
    if (event === "error") child.emit("error", Error("synthetic launch failure"));
    if (event === "close") child.emit("close", 1);
    if (event === "stdin") child.stdin.emit("error", Error("synthetic pipe failure"));
    child.emit("close", 1);
    assert.equal(calls.notify.length, 1);
    assert.equal(calls.notify[0].tid, "test terminal");
  });
}

test("successful popup creates no duplicate OS notification", t => {
  const {bridge, child, calls} = setup(t);
  bridge.sendQuestion("test terminal", "Codex", "Question: example");
  child.emit("close", 0);
  assert.equal(calls.notify.length, 0);
});

test("unique completion is routed once and repeated preview is suppressed", t => {
  const {root, bridge} = setup(t);
  const route = pending(root);
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), true);
  const record = JSON.parse(fs.readFileSync(route));
  assert.equal(record.session_id, "synthetic-session");
  assert.equal(record.terminal_id, "test terminal");
  assert.match(record.focus_uri, /tid=test%20terminal$/);
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), true);
  assert.equal(bridge.routeCompletion("another terminal", "测试完成。"), false);
});

test("missing, corrupt, expired, future and unmatched records are ignored", t => {
  const {root, bridge} = setup(t);
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), false);
  for (const extra of [{created_ms: Date.now() - 60000}, {created_ms: Date.now() + 60000}, {response: "other"}, {session_id: ""}]) {
    pending(root, extra);
    assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), false);
  }
  fs.writeFileSync(path.join(root, "completion", token + ".json"), "invalid json");
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), false);
});

test("ambiguous same-text completions do not guess a terminal", t => {
  const {root, bridge} = setup(t);
  const one = pending(root);
  const two = pending(root, {token: "22222222-2222-4222-8222-222222222222"});
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), true);
  assert.equal(fs.existsSync(one), false);
  assert.equal(fs.existsSync(two), false);
});

test("Unicode completion preview is truncated by grapheme, with whitespace normalized", t => {
  const {root, bridge} = setup(t);
  const emoji = "👩‍💻";
  pending(root, {response: `  ${emoji.repeat(201)}\n  `});
  assert.equal(bridge.routeCompletion("test terminal", emoji.repeat(197) + "..."), true);
});

test("debug is off by default, and opt-in debug excludes message, session and terminal data", t => {
  const {root, bridge, dependencies, options} = setup(t);
  bridge.log("example", {session_id: "private-test-value"});
  assert.equal(fs.existsSync(path.join(root, "events.jsonl")), false);
  const debug = createBridge(options, {...dependencies, process: {platform: "win32", env: {CODEX_NOTIFY_DEBUG: "1"}}});
  debug.log("example", {response: "private-test-value"});
  const text = fs.readFileSync(path.join(root, "events.jsonl"), "utf8");
  assert.equal(text.includes("private-test-value"), false);
  assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ["event", "time"]);
});

for (const event of ["error", "close", "stdin"]) {
  test(`privacy mode hides both title and body on asynchronous ${event} fallback`, t => {
    const {bridge, child, calls} = setup(t, {process: {platform: "win32", env: {CODEX_NOTIFY_PREVIEW: "0"}}});
    bridge.sendQuestion("test terminal", "PRIVATE_TITLE", "Question: PRIVATE_BODY");
    if (event === "error") child.emit("error", Error("synthetic failure"));
    if (event === "close") child.emit("close", 1);
    if (event === "stdin") child.stdin.emit("error", Error("synthetic failure"));
    assert.equal(calls.notify.length, 1);
    assert.equal(calls.notify[0].tid, "test terminal");
    assert.equal(JSON.stringify(calls.notify).includes("PRIVATE_"), false);
  });
}

test("preview-enabled notifications retain their original title and message", t => {
  const {bridge} = setup(t);
  assert.deepEqual(bridge.safeNotification("Original title", "Original message"),
    {title: "Original title", message: "Original message"});
});

test("repeated older completion cannot claim a newer same-text pending completion", t => {
  const {root, bridge} = setup(t);
  pending(root);
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), true);
  const newer = pending(root, {token: "22222222-2222-4222-8222-222222222222", session_id: "another-session"});
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), true);
  assert.equal(fs.existsSync(newer), false);
});

test("exclusive route creation by another terminal does not report a successful claim", t => {
  const {root, options, dependencies} = setup(t);
  const route = pending(root);
  const racingFs = {...fs, writeFileSync: (filename, data, opts) => {
    if (filename === route && opts.flag === "wx") {
      fs.writeFileSync(route, JSON.stringify({session_id: "synthetic-session", terminal_id: "another-terminal"}));
      throw Object.assign(Error("synthetic race"), {code: "EEXIST"});
    }
    return fs.writeFileSync(filename, data, opts);
  }};
  const bridge = createBridge(options, {...dependencies, fs: racingFs});
  assert.equal(bridge.routeCompletion("test terminal", "测试完成。"), false);
  assert.equal(JSON.parse(fs.readFileSync(route)).terminal_id, "another-terminal");
});
