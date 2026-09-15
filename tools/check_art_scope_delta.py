#!/usr/bin/env python3
"""Report baseline policy failures and reject any additional failure in the PR.

This is a non-regression check, NOT full exact-1080 policy acceptance. Neither
side launches a display suite; both execute the existing static policy checker.
The pinned baseline is current main when the art branch was integrated.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = "8039a0c19570e022cfc6ec855b77dd014da3e553"
CHECKER = "tools/check_first_playable_1080.py"
TEST = "tests/tooling/test_ui_first_playable_scope.py"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=60).stdout


def issues(root: Path) -> list[str]:
    spec = importlib.util.spec_from_file_location("policy_checker", root / CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError("policy checker unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.manifest_issues(module.load_manifest(root / "config/first_playable_1080_gate.json"),
                                  root, module.repository_paths(root))


def main() -> int:
    # The baseline comparison cannot be used to weaken or replace the checker.
    for path in (CHECKER, TEST):
        if git("show", f"{BASE}:{path}") != (ROOT / path).read_text(encoding="utf-8"):
            raise RuntimeError("scope checker/tests changed; independent review required: " + path)
    with tempfile.TemporaryDirectory(prefix="zerkov-scope-baseline-") as directory:
        baseline = Path(directory) / "baseline"
        git("worktree", "add", "--detach", str(baseline), BASE)
        try:
            before = issues(baseline)
            after = issues(ROOT)
        finally:
            git("worktree", "remove", "--force", str(baseline))
    for issue in sorted(before):
        print("PRE_EXISTING_BASELINE_ISSUE: " + issue)
    for issue in sorted(set(after) - set(before)):
        print("NEW_POLICY_FAILURE: " + issue)
    new = set(after) - set(before)
    print(f"ART_SCOPE_DELTA_RESULT baseline_issues={len(before)} current_issues={len(after)} "
          f"new_issues={len(new)} full_policy_pass={not after}")
    return 1 if new else 0


if __name__ == "__main__":
    raise SystemExit(main())
