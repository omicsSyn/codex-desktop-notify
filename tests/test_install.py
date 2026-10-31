import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
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
        self.assertEqual(patched.replace(installer.INTEGRATION, "").replace(installer.DISPATCH, ""), CLEAN)

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
