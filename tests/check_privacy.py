"""Check tracked/public source files for common accidental disclosures."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    "Linux home directory": re.compile(r"/home/[\w.-]+/"),
    "WSL mounted personal/project path": re.compile(r"/mnt/[a-z]/[^\s'\"<>]+"),
    "Windows user directory": re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+(?!<|%|\$)[\w.-]+", re.I),
    "GitHub credential": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})"),
    "API key": re.compile(r"\bsk-[A-Za-z0-9_-]{24,}"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}
RUNTIME_SUFFIXES = {".jsonl", ".log", ".bak", ".original", ".vsix", ".zip"}


def main():
    # Check the exact publication set once git is initialized. Before that,
    # inspect source files only, excluding interpreter caches.
    if (ROOT / ".git").exists():
        output = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout
        files = [ROOT / name.decode("utf-8") for name in output.split(b"\0") if name]
    else:
        files = [p for p in ROOT.rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    errors = []
    for path in files:
        relative = path.relative_to(ROOT)
        if (path.suffix in RUNTIME_SUFFIXES or path.name.startswith(".env") or
                {"payloads", "completion"}.intersection(relative.parts[:-1])):
            errors.append(f"{relative}: runtime/credential file must not be published")
        text = path.read_text(encoding="utf-8-sig")
        for label, pattern in PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{relative}: possible {label}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"PASS: {len(files)} public files; no detected credentials, personal home/mount paths or runtime artifacts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
