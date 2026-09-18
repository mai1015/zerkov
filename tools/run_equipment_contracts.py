#!/usr/bin/env python3
"""Real native equipment/UI and separate-process local-save contracts at 1080p."""
from __future__ import annotations
import argparse
from collections.abc import Callable, Iterator
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ERRORS = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|ObjectDB instances leaked|resources still in use|_TIMEOUT")


def execute(command: list[str], env: dict[str, str], marker: str | None = None, timeout: int = 180) -> str:
    print("EQUIPMENT_COMMAND:", command, flush=True)
    try:
        result = subprocess.run(command, env=env, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        # TimeoutExpired.stdout can be bytes even with text=True. Preserve the
        # compiler/runtime diagnostic before the outer handler reports timeout.
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        print(output, end="", flush=True)
        print(f"\nEQUIPMENT_COMMAND_TIMEOUT after {timeout}s: {command}", flush=True)
        raise
    print(result.stdout, end="", flush=True)
    if result.returncode or ERRORS.search(result.stdout):
        raise RuntimeError(f"Native command/diagnostics failed: {result.returncode}: {command}")
    if marker and not re.search(rf"(?m)^{re.escape(marker)} checks=[1-9][0-9]* failures=0(?:\s|$)", result.stdout):
        raise RuntimeError(f"Missing zero-failure marker: {marker}")
    return result.stdout


@contextmanager
def cleanup_after(cleanup: Callable[[], object]) -> Iterator[None]:
    """Always clean isolated saves without replacing an earlier stage failure."""
    try:
        yield
    except BaseException:
        try:
            cleanup()
        except Exception as error:
            print("EQUIPMENT_CLEANUP_FAILED (original failure retained):", error, flush=True)
        raise
    else:
        # A cleanup-only failure is still a failed validation run.
        cleanup()


def import_runtime_project(base: list[str], env: dict[str, str], project: Path) -> None:
    """Import runtime dependencies without running unrelated editor dashboards.

    The temporary project's GDExtensions and autoloads remain enabled. Restore
    project.godot byte-for-byte before gameplay; this is not an editor audit.
    """
    config = project / "project.godot"
    original = config.read_bytes()
    text = original.decode("utf-8")
    section = re.compile(r"(?ms)(^\[editor_plugins\]\r?\n)(.*?)(?=^\[|\Z)")
    def disable(match: re.Match[str]) -> str:
        body = re.sub(r"(?m)^enabled=.*$", "enabled=PackedStringArray()", match[2])
        return match[1] + body
    try:
        config.write_text(section.sub(disable, text), encoding="utf-8")
        print("EQUIPMENT_IMPORT: editor dashboards disabled in temporary copy; native extensions unchanged", flush=True)
        execute(base + ["--editor", "--import", "--quit"], env)
    finally:
        config.write_bytes(original)
    if config.read_bytes() != original:
        raise RuntimeError("Runtime project configuration was not restored")


def verify_local_flow(base: list[str], env: dict[str, str]) -> None:
    """Run the unchanged full local-flow driver in the same native project."""
    namespace = "localflow_" + uuid.uuid4().hex
    command = base + ["--script", "res://tests/local/native_local_flow_contract.gd", "--"]
    full_env = {**env, "ZERKOV_TEST_SCENARIO": "full"}
    with cleanup_after(lambda: execute(command + ["cleanup", namespace], full_env, "LOCAL_FLOW_CLEANUP", 30)):
        log = execute(command + ["run", namespace], full_env, "NATIVE_LOCAL_FLOW_RESULT", 660)
        match = re.search(r"(?m)^LOCAL_FLOW_FINGERPRINT ([a-f0-9]{64})$", log)
        if not match:
            raise RuntimeError("Missing local-flow profile fingerprint")
        for _ in range(2):
            execute(command + ["verify", namespace, match[1]], full_env, "LOCAL_FLOW_VERIFY")
    print("EQUIPMENT_LOCAL_FLOW_COMPLETE", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, help="Record native fullscreen AVI clips; not a real-time FPS measurement")
    parser.add_argument("--local-flow", action="store_true", help="Also verify extraction/death/save-retry and two fresh-process reloads")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"}
    engine = str(args.godot.expanduser().resolve(strict=True))
    required = json.loads((source / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
    if execute([engine, "--version"], env).strip() != required:
        raise RuntimeError("Engine version does not match lock")
    with tempfile.TemporaryDirectory(prefix="zerkov-equipment-") as temp:
        project = Path(temp) / "project"
        shutil.copytree(source, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
        env["XDG_DATA_HOME"] = str(Path(temp) / "user")
        base = [engine, "--headless", "--path", str(project), "--resolution", "1920x1080", "--audio-driver", "Dummy"]
        import_runtime_project(base, env, project)
        # Dynamic input drivers must compile before any profiles or movies are
        # created. A failed preload can prevent the in-script watchdog starting.
        for path in (
            "tests/equipment/equipment_ui_flow.gd",
            "tests/equipment/equipment_gesture_driver.gd",
            "tests/equipment/equipment_deploy_driver.gd",
        ):
            execute(base + ["--check-only", "--script", "res://" + path], env, timeout=30)
        for path, marker in [
            ("tests/equipment/equipment_contract.gd", "EQUIPMENT_CONTRACT_RESULT"),
            ("tests/raid/equipped_item_reconciliation_contract.gd", "EQUIPPED_ITEM_RECONCILIATION_RESULT"),
            ("tests/raid/inventory_ability_reconciliation_contract.gd", "INVENTORY_ABILITY_RECONCILIATION_RESULT"),
            ("tests/presentation/character_ui_binding_8_6_contract.gd", "CHARACTER_UI_BINDING_8_6_RESULT"),
        ]:
            execute(base + ["--script", "res://" + path], env, marker)
        namespace = "equipflow_" + uuid.uuid4().hex
        saved: list[str] = []
        cleanup_command = base + ["--script", "res://tests/equipment/equipment_ui_flow.gd", "--", "cleanup", namespace]
        with cleanup_after(lambda: execute(cleanup_command, env, "EQUIPMENT_UI_RESULT", 30)):
            for stage in ("create", "resume", "deploy"):
                command = base.copy()
                stage_env = {**env, "ZERKOV_EQUIPMENT_MOVIE": "0"}
                if args.capture_dir:
                    output = args.capture_dir.resolve()
                    output.mkdir(parents=True, exist_ok=True)
                    command.remove("--headless")
                    command += ["--fullscreen", "--rendering-method", "gl_compatibility", "--write-movie", str(output / (stage + ".avi")), "--fixed-fps", "15"]
                    stage_env["ZERKOV_EQUIPMENT_MOVIE"] = "1"
                log = execute(command + ["--script", "res://tests/equipment/equipment_ui_flow.gd", "--", stage, namespace] + saved,
                              stage_env, "EQUIPMENT_UI_RESULT", 240)
                match = re.search(r"(?m)^EQUIPMENT_UI_SAVE item=([1-9][0-9]*) fingerprint=([0-9a-f]{64})$", log)
                if not match:
                    raise RuntimeError("Missing exact saved identity/fingerprint")
                saved = list(match.groups())
        if args.local_flow:
            verify_local_flow(base, env)
    print("EQUIPMENT_RUNNER_COMPLETE")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("EQUIPMENT_RUNNER_FAILED:", error, flush=True)
        raise SystemExit(1)
