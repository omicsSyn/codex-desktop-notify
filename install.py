#!/usr/bin/env python3
"""Install the portable popup bridge on Windows or WSL. Dry run by default."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
EXTENSION_ID = "wenbopan.vscode-terminal-osc-notifier"
SUPPORTED_VERSION = "0.1.4"
BEGIN = "// BEGIN codex-desktop-notify\n"
END = "// END codex-desktop-notify\n"
INTEGRATION = BEGIN + '''var desktopNotifyBridge = require("./codex-desktop-notify.js").createBridge({
  vscode, terminals: idToTerminal,
  getContext: () => extensionCtx, getNotifier: () => notifier
});
function completionRoutingLog(event) { desktopNotifyBridge.log(event); }
function routeCodexCompletion(tid, message) { return desktopNotifyBridge.routeCompletion(tid, message); }
function sendCodexQuestionPopup(tid, title, message) { return desktopNotifyBridge.sendQuestion(tid, title, message); }
''' + END
DISPATCH = "  if (routeCodexCompletion(tid, message)) return true;\n  if (sendCodexQuestionPopup(tid, title, message)) return true;\n"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Extension source differs from the supported layout; nothing applied")
    return text.replace(old, new, 1)


def patch_extension(text):
    """Preserve the bundle and unrelated customizations; guard all replacement anchors."""
    if "\r\n" in text:
        if text.count("\r\n") != text.count("\n"):
            raise ValueError("Mixed extension line endings; inspect before updating")
        return _patch_lf(text.replace("\r\n", "\n")).replace("\n", "\r\n")
    return _patch_lf(text)


def _patch_lf(text):
    if BEGIN in text:
        if text.count(INTEGRATION) != 1 or text.count(DISPATCH) != 1:
            raise ValueError("Existing bridge differs; inspect before updating")
        return text
    legacy = "// Local Codex notification bridge: preserve terminal routing and use the same\n"
    dispatch_anchor = "  if (!preferOs) return;\n"
    if legacy in text:
        # Upgrade the earlier standalone bridge without copying its local paths.
        if text.count(legacy) != 1:
            raise ValueError("Ambiguous existing bridge")
        start = text.index(legacy)
        end = text.index("function sendOsNotification(", start)
        text = text[:start] + INTEGRATION + text[end:]
        old_dispatch = "  if (routeCodexCompletion(tid, message)) return true;\n  if (sendCodexQuestionPopup(tid, title, message)) return;\n"
        text = replace_once(text, old_dispatch, DISPATCH)
    else:
        # A clean upstream 0.1.4 bundle.
        if any(name in text for name in ("function routeCodexCompletion(", "function sendCodexQuestionPopup(")):
            raise ValueError("Unknown notification customization; nothing applied")
        text = replace_once(text, "function sendOsNotification(", INTEGRATION + "function sendOsNotification(")
        text = replace_once(text, dispatch_anchor, dispatch_anchor + DISPATCH)
    return text


def run(args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20).stdout


def windows_environment(powershell):
    code = """$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
@{local=[Environment]::GetFolderPath('LocalApplicationData');profile=$env:USERPROFILE}|ConvertTo-Json -Compress
"""
    encoded = base64.b64encode(code.encode("utf-16le")).decode("ascii")
    return json.loads(run([powershell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]).decode("utf-8-sig"))


def local_path(windows_path):
    if os.name == "nt":
        return Path(windows_path)
    return Path(run(["wslpath", "-u", windows_path]).decode().strip())


def windows_path(path):
    if os.name == "nt":
        return str(path.resolve())
    return run(["wslpath", "-w", str(path.resolve())]).decode().strip()


def validate_extension(directory):
    manifest = json.loads((directory / "package.json").read_text(encoding="utf-8"))
    if f"{manifest.get('publisher')}.{manifest.get('name')}" != EXTENSION_ID:
        raise ValueError("This is not the supported Terminal Notification extension")
    if manifest.get("version") != SUPPORTED_VERSION:
        raise ValueError(f"Only extension {SUPPORTED_VERSION} is supported; inspect newer releases first")
    return directory / "dist" / "extension.js"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_with_backup(changes, backup_root):
    """Snapshot every original before writing; roll back partial failures."""
    before = {path: path.read_bytes() if path.exists() else None for path in changes}
    changes = {path: data for path, data in changes.items() if before[path] != data}
    if not changes:
        return None
    backup = backup_root / datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
    backup.mkdir(parents=True, exist_ok=False)
    records = []
    for i, (path, data) in enumerate(changes.items()):
        original = before[path]
        filename = f"{i}.original" if original is not None else None
        if filename:
            (backup / filename).write_bytes(original)
        records.append({"path": str(path.resolve()), "original": filename,
                        "before_sha256": digest(original) if original is not None else None,
                        "after_sha256": digest(data)})
    (backup / "manifest.json").write_text(json.dumps({"files": records}, indent=2) + "\n", encoding="utf-8")
    written = []
    try:
        for path, data in changes.items():
            current = path.read_bytes() if path.exists() else None
            if current != before[path]:
                raise ValueError(f"File changed during installation: {path}")
            path.parent.mkdir(parents=True, exist_ok=True)
            written.append(path)
            path.write_bytes(data)
            if path.read_bytes() != data:
                raise OSError(f"Write verification failed: {path}")
    except Exception:
        for path in reversed(written):
            if before[path] is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(before[path])
        raise
    return backup


def restore(backup):
    records = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))["files"]
    originals = {}
    for item in records:
        path = Path(item["path"])
        if not path.is_file() or digest(path.read_bytes()) != item["after_sha256"]:
            raise ValueError(f"File changed since installation; refusing to overwrite: {path}")
        original = (backup / item["original"]).read_bytes() if item["original"] else None
        if original is not None and digest(original) != item["before_sha256"]:
            raise ValueError("Backup checksum mismatch; nothing restored")
        originals[path] = original
    for path, data in originals.items():
        if data is None:
            path.unlink()
        else:
            path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension-dir", type=Path, help="Installed extension folder (optional)")
    parser.add_argument("--apply", action="store_true", help="Back up files and install the bridge")
    parser.add_argument("--restore", type=Path, metavar="BACKUP", help="Restore an installer backup, checking hashes first")
    args = parser.parse_args()
    if args.restore:
        if args.apply or args.extension_dir:
            parser.error("--restore cannot be combined with installation options")
        restore(args.restore.resolve())
        print("Restored installation files. Reload the VS Code window. Codex config was not changed.")
        return
    powershell = shutil.which("powershell.exe")
    if not powershell:
        raise ValueError("Windows PowerShell is required. Run on Windows or a Windows-connected WSL installation")
    host = windows_environment(powershell)
    state = local_path(host["local"]) / "CodexDesktopNotify"
    directory = args.extension_dir
    if directory is None:
        directory = local_path(host["profile"]) / ".vscode" / "extensions" / f"{EXTENSION_ID}-{SUPPORTED_VERSION}"
    directory = directory.resolve()
    asset = validate_extension(directory)
    original = asset.read_bytes()
    patched = patch_extension(original.decode("utf-8")).encode("utf-8")
    command_args = [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                    "-File", windows_path(state / "notify-done.ps1"), "codex"]
    command = subprocess.list2cmdline(command_args) if os.name == "nt" else shlex.join(command_args)
    hooks = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command}]}]}}
    changes = {asset: patched, directory / "dist" / "codex-desktop-notify.js": (ROOT / "bridge.js").read_bytes(),
               state / "notify-done.ps1": (ROOT / "notify-done.ps1").read_bytes(),
               state / "hooks.example.json": (json.dumps(hooks, ensure_ascii=False, indent=2) + "\n").encode("utf-8")}
    print(f"Extension: {directory}")
    print(f"Runtime directory: {state}")
    if args.apply:
        backup = write_with_backup(changes, state / "backups")
        print(f"Installed. Backup: {backup}" if backup else "Already installed; no files changed.")
        print("Reload VS Code to load the extension change.")
    else:
        print("Dry run: no files changed. Use --apply to install.")
    print("\nMerge this Stop hook into the hooks.json next to your active Codex config; keep other hooks:")
    print(json.dumps(hooks, ensure_ascii=False, indent=2))
    print("\nMerge these settings into the existing [tui] table in config.toml:")
    print('notifications = ["approval-requested", "plan-mode-prompt", "async-question", "agent-turn-complete"]')
    print('notification_method = "osc9"\nnotification_condition = "always"')
    print("\nRestart Codex and use /hooks to review/trust this hook. The installer never edits hook trust.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
