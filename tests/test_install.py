import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("installer", ROOT / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

# Small synthetic bundle: no installed extension, personal paths or configs.
CLEAN = '''var idToTerminal = new Map();
function sendOsNotification(tid, title, message) {
  const preferOs = getSetting("preferOsNotifications", true);
  if (!preferOs) return;
  notifier.notify({title, message, tid});
}
function sendVsCodeNotification(tid, title, message) {
  vscode.window.showInformationMessage(title + ": " + message);
}
'''


class InstallationTests(unittest.TestCase):
    def test_main_installs_in_isolated_fixture_and_second_run_is_noop(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            extension = root / "extension"
            (extension / "dist").mkdir(parents=True)
            (extension / "package.json").write_text(json.dumps({
                "publisher": "wenbopan", "name": "vscode-terminal-osc-notifier", "version": "0.1.4"}))
            asset = extension / "dist" / "extension.js"
            asset.write_text(CLEAN)
            original = asset.read_bytes()
            with patch.object(installer.shutil, "which", return_value="powershell.exe"), \
                    patch.object(installer, "windows_environment", return_value={"local": str(root), "profile": str(root)}), \
                    patch.object(installer, "local_path", side_effect=Path), \
                    patch.object(installer, "windows_path", return_value=r"C:\Tools\CodexDesktopNotify\notify-done.ps1"), \
                    patch("sys.argv", ["install.py", "--extension-dir", str(extension)]), \
                    contextlib.redirect_stdout(io.StringIO()):
                installer.main()
                self.assertEqual(asset.read_bytes(), original)
                self.assertFalse((root / "CodexDesktopNotify").exists())
                with patch("sys.argv", ["install.py", "--extension-dir", str(extension), "--apply"]):
                    installer.main()
                    installed = asset.read_bytes()
                    self.assertNotEqual(installed, original)
                    state = root / "CodexDesktopNotify"
                    self.assertTrue((state / "notify-done.ps1").exists())
                    hooks = json.loads((state / "hooks.example.json").read_text())
                    self.assertIn("Stop", hooks["hooks"])
                    backups = list((state / "backups").iterdir())
                    installer.main()
                    self.assertEqual(asset.read_bytes(), installed)
                    self.assertEqual(list((state / "backups").iterdir()), backups)
            installer.restore(backups[0])
            self.assertEqual(asset.read_bytes(), original)
            self.assertFalse((extension / "dist" / "codex-desktop-notify.js").exists())
            self.assertFalse((state / "notify-done.ps1").exists())

    def test_clean_patch_is_minimal_and_idempotent(self):
        patched = installer.patch_extension(CLEAN)
        self.assertEqual(installer.patch_extension(patched), patched)
        restored = patched.replace(installer.INTEGRATION, "").replace(installer.DISPATCH, "")
        self.assertEqual(restored.replace(installer.VSCODE_HEADER + installer.PRIVACY, installer.VSCODE_HEADER), CLEAN)

    def test_crlf_patch_preserves_all_original_line_endings(self):
        original = CLEAN.replace("\n", "\r\n")
        patched = installer.patch_extension(original)
        self.assertEqual(installer.patch_extension(patched), patched)
        self.assertEqual(patched.count("\n"), patched.count("\r\n"))
        restored = patched.replace(installer.INTEGRATION.replace("\n", "\r\n"), "")
        restored = restored.replace(installer.DISPATCH.replace("\n", "\r\n"), "")
        restored = restored.replace((installer.VSCODE_HEADER + installer.PRIVACY).replace("\n", "\r\n"),
                                    installer.VSCODE_HEADER.replace("\n", "\r\n"))
        self.assertEqual(restored, original)
        with self.assertRaises(ValueError):
            installer.patch_extension(CLEAN.replace("\n", "\r\n", 1))

    def test_prior_public_patch_upgrades_both_privacy_exits(self):
        previous = CLEAN.replace("function sendOsNotification(", installer.INTEGRATION + "function sendOsNotification(")
        previous = previous.replace("  if (!preferOs) return;\n", "  if (!preferOs) return;\n" + installer.OLD_DISPATCH)
        patched = installer.patch_extension(previous)
        self.assertEqual(patched.count(installer.PRIVACY), 2)
        self.assertEqual(installer.patch_extension(patched), patched)

    @unittest.skipUnless(shutil.which("node"), "Node.js is required for the integration test")
    def test_privacy_applies_to_actual_patched_os_and_vscode_entrypoints(self):
        script = r'''
const vm = require('node:vm'), assert = require('node:assert/strict');
const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const {createBridge} = require(input.bridge);
for (const preferOs of [true, false]) {
  const os = [], ui = [];
  const context = {
    vscode: {env: {uriScheme: 'vscode'}, window: {showInformationMessage: message => ui.push(message)}},
    extensionCtx: {extension: {id: 'wenbopan.vscode-terminal-osc-notifier'}},
    notifier: {notify: options => os.push(options)}, getSetting: () => preferOs,
    require: () => ({createBridge: options => createBridge(options, {
      fs: {existsSync: () => false}, process: {platform: 'win32', env: {CODEX_NOTIFY_PREVIEW: '0'}}
    })})
  };
  vm.createContext(context); vm.runInContext(input.code, context);
  context.sendOsNotification('example', 'PRIVATE_TITLE', 'Question: PRIVATE_BODY');
  context.sendVsCodeNotification('example', 'PRIVATE_TITLE', 'Question: PRIVATE_BODY');
  assert.equal(os.length, preferOs ? 1 : 0);
  assert.equal(ui.length, 1);
  assert.equal(JSON.stringify({os, ui}).includes('PRIVATE_'), false);
  if (preferOs) assert.equal(os[0].tid, 'example');
}
'''
        subprocess.run([shutil.which("node"), "-e", script], check=True, timeout=15, text=True,
                       input=json.dumps({"code": installer.patch_extension(CLEAN), "bridge": str(ROOT / "bridge.js")}))

    def test_legacy_patch_preserves_other_customizations(self):
        legacy = CLEAN.replace("function sendOsNotification(",
                               "// Local Codex notification bridge: preserve terminal routing and use the same\n"
                               "// colored popup renderer as the existing completion hook.\n"
                               "function routeCodexCompletion() { return false; }\n"
                               "function sendCodexQuestionPopup() { return false; }\n"
                               "function sendOsNotification(")
        legacy = legacy.replace("  if (!preferOs) return;\n", "  if (!preferOs) return;\n"
                                "  if (routeCodexCompletion(tid, message)) return true;\n"
                                "  if (sendCodexQuestionPopup(tid, title, message)) return;\n")
        prefix = "// An unrelated user customization stays intact.\n"
        patched = installer.patch_extension(prefix + legacy)
        self.assertTrue(patched.startswith(prefix))
        self.assertIn(installer.INTEGRATION, patched)
        self.assertEqual(installer.patch_extension(patched), patched)

    def test_unknown_or_partial_bundle_rejected(self):
        for text in ["unknown bundle", CLEAN + CLEAN, installer.BEGIN + CLEAN,
                     "function routeCodexCompletion() {}\n" + CLEAN]:
            with self.subTest(text=text[:35]), self.assertRaises(ValueError):
                installer.patch_extension(text)

    def test_wrong_extension_version_or_identity_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for manifest in [{"publisher": "example", "name": "other", "version": "0.1.4"},
                             {"publisher": "wenbopan", "name": "vscode-terminal-osc-notifier", "version": "9.0.0"}]:
                (directory / "package.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    installer.validate_extension(directory)

    def test_backup_restore_is_exact_and_created_files_removed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            existing, created = root / "existing.js", root / "runtime.ps1"
            existing.write_bytes(b"original\r\n")
            backup = installer.write_with_backup({existing: b"patched\n", created: b"new"}, root / "backups")
            self.assertEqual(existing.read_bytes(), b"patched\n")
            installer.restore(backup)
            self.assertEqual(existing.read_bytes(), b"original\r\n")
            self.assertFalse(created.exists())
            self.assertTrue((backup / "manifest.json").exists())

    def test_restore_refuses_later_user_changes_before_any_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            one, two = root / "one", root / "two"
            one.write_bytes(b"old one")
            two.write_bytes(b"old two")
            backup = installer.write_with_backup({one: b"new one", two: b"new two"}, root / "backups")
            two.write_bytes(b"later user edit")
            with self.assertRaises(ValueError):
                installer.restore(backup)
            self.assertEqual(one.read_bytes(), b"new one")
            self.assertEqual(two.read_bytes(), b"later user edit")

    def test_restore_io_failure_rolls_back_and_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            one, two = root / "one", root / "two"
            one.write_bytes(b"old one")
            two.write_bytes(b"old two")
            backup = installer.write_with_backup({one: b"new one", two: b"new two"}, root / "backups")
            actual = installer.os.replace

            def fail_second(staged, target):
                # Manifests use resolved paths; Windows TEMP may use an 8.3
                # alias while the actual destination uses the long path.
                if Path(target).resolve() == two.resolve():
                    raise OSError("synthetic second-file I/O failure")
                return actual(staged, target)

            with patch.object(installer.os, "replace", fail_second), self.assertRaises(OSError):
                installer.restore(backup)
            self.assertEqual(one.read_bytes(), b"new one")
            self.assertEqual(two.read_bytes(), b"new two")
            self.assertEqual(list(root.glob(".codex-notify-*")), [])
            installer.restore(backup)
            self.assertEqual(one.read_bytes(), b"old one")
            self.assertEqual(two.read_bytes(), b"old two")

    def test_restore_resumes_after_hard_interruption_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            one, two, created = root / "one", root / "two", root / "created"
            one.write_bytes(b"old one")
            two.write_bytes(b"old two")
            backup = installer.write_with_backup({one: b"new one", two: b"new two", created: b"new"}, root / "backups")
            # Simulate a process being killed after these two operations.
            one.write_bytes(b"old one")
            created.unlink()
            installer.restore(backup)
            installer.restore(backup)
            self.assertEqual(one.read_bytes(), b"old one")
            self.assertEqual(two.read_bytes(), b"old two")
            self.assertFalse(created.exists())

    def test_rollback_io_failure_after_deletion_can_be_retried(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            created, target = root / "created", root / "target"
            target.write_bytes(b"old")
            backup = installer.write_with_backup({created: b"new file", target: b"installed"}, root / "backups")
            with patch.object(installer.os, "replace", side_effect=OSError("synthetic replace failure")), self.assertRaises(OSError):
                installer.restore(backup)
            # Rollback of the deletion also failed: the same backup must still
            # permit a later safe retry once the underlying I/O error is gone.
            installer.restore(backup)
            self.assertFalse(created.exists())
            self.assertEqual(target.read_bytes(), b"old")

    def test_restore_rollback_preserves_a_concurrent_user_edit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            one, two = root / "one", root / "two"
            one.write_bytes(b"old one")
            two.write_bytes(b"old two")
            backup = installer.write_with_backup({one: b"new one", two: b"new two"}, root / "backups")
            actual = installer.os.replace

            def user_edit_during_failure(staged, target):
                if Path(target).resolve() == two.resolve():
                    one.write_bytes(b"later user edit")
                    raise OSError("synthetic I/O failure")
                return actual(staged, target)

            with patch.object(installer.os, "replace", user_edit_during_failure), self.assertRaises(OSError):
                installer.restore(backup)
            self.assertEqual(one.read_bytes(), b"later user edit")
            self.assertEqual(two.read_bytes(), b"new two")
            with self.assertRaises(ValueError):
                installer.restore(backup)

    def test_corrupt_backup_refused_and_noop_creates_no_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / "asset"
            target.write_bytes(b"unchanged")
            self.assertIsNone(installer.write_with_backup({target: b"unchanged"}, root / "backups"))
            self.assertFalse((root / "backups").exists())
            backup = installer.write_with_backup({target: b"new"}, root / "backups")
            (backup / "0.original").write_bytes(b"corrupted")
            with self.assertRaises(ValueError):
                installer.restore(backup)
            self.assertEqual(target.read_bytes(), b"new")


if __name__ == "__main__":
    unittest.main()
