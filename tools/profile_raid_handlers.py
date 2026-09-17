#!/usr/bin/env python3
"""Measure the real local raid: relay safety scan versus actual callback body.

Instrumentation is applied only to a temporary project copy at the ORIGINAL
script paths, preserving lexical authority identity. No guard is skipped, no
mutable verdict is cached, and no production clock/save settings are changed.
An uninstrumented control must produce the same stage-end authority digests.
This measures CPU tick cost, not windowed FPS or complete encounter acceptance.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ERRORS = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|ObjectDB instances leaked|resources still in use|_TIMEOUT")
PROBE_PATH = "tests/local/raid_handler_profile_probe.gd"
PROBE = r'''extends RefCounted
static var collecting: bool = false
static var timings: Dictionary = {}
static var details: Dictionary = {}

static func record(id: StringName, scan: int, body: int) -> void:
	if not collecting: return
	if not timings.has(id): timings[id] = {"scan":[], "body":[]}
	timings[id].scan.append(scan)
	timings[id].body.append(body)

static func detail(id: String, usec: int) -> void:
	if not collecting: return
	if not details.has(id): details[id] = []
	details[id].append(usec)

static func stats(samples: Array) -> Dictionary:
	if samples.is_empty(): return {"count":0}
	var sorted := samples.duplicate()
	sorted.sort()
	var total: float = 0.0
	for value in sorted: total += float(value)
	return {"count":sorted.size(), "mean_us":total / sorted.size(),
		"median_us":sorted[sorted.size() / 2],
		"p95_us":sorted[mini(sorted.size() - 1, int(ceil(sorted.size() * 0.95)) - 1)],
		"p99_us":sorted[mini(sorted.size() - 1, int(ceil(sorted.size() * 0.99)) - 1)],
		"max_us":sorted[-1]}

func run(game, tree: SceneTree, check: Callable) -> bool:
	for _i in range(8):
		if not check.call(game.advance(), "profile warmup executes production tick"): return false
	var digests: Array[String] = []
	for stage: String in ["idle", "move", "combat"]:
		timings = {}; details = {}
		var total: Array = []
		var count: int = 144 if stage == "combat" else 64
		if stage == "move": key(KEY_D, true)
		if stage == "combat": key(KEY_R, true); key(KEY_R, false)
		collecting = true
		for index in range(count):
			if stage == "combat" and index >= 128 and index % 8 == 0:
				for down: bool in [true, false]:
					var event := InputEventMouseButton.new()
					event.position = Vector2(1300, 540)
					event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
					Input.parse_input_event(event)
					Input.flush_buffered_events()
			var start := Time.get_ticks_usec()
			var ok: bool = game.advance()
			total.append(Time.get_ticks_usec() - start)
			if not check.call(ok and game._mode == "raid", "profile real tick without failure or unexpected terminal"): return false
			if index % 16 == 15: await tree.process_frame
		collecting = false
		if stage == "move": key(KEY_D, false)
		var row := {"stage":stage, "root":stats(total), "handlers":{}, "details":{}, "dispatch_work":game._session.raid.dispatch_work_counts() if game._session.raid.has_method("dispatch_work_counts") else {}}
		var ids := timings.keys(); ids.sort()
		for id in ids:
			row.handlers[String(id)] = {"dispatch_validation":stats(timings[id].scan), "body":stats(timings[id].body)}
		for id in details: row.details[id] = stats(details[id])
		print("RAID_HANDLER_PROFILE ", JSON.stringify(row))
		var digest: String = game._session.raid.state_digest()
		if not check.call(digest.length() == 64, "profile authority digest exists"): return false
		digests.append(digest)
	print("RAID_PROFILE_DIGESTS ", JSON.stringify(digests))
	return true

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.physical_keycode = code; event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()
'''


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError("Instrumentation anchor drift: " + old[:100])
    return text.replace(old, new, 1)


def instrument(project: Path, enabled: bool) -> None:
    (project / PROBE_PATH).write_text(PROBE, encoding="utf-8")
    entry = project / "tests/local/native_local_flow_contract.gd"
    text = entry.read_text(encoding="utf-8")
    anchor = '\tif OS.get_environment("ZERKOV_TEST_SCENARIO") == "clock":'
    addition = '\tif OS.get_environment("ZERKOV_TEST_SCENARIO") == "handler_profile":\n'
    addition += '\t\tvar probe = load("res://' + PROBE_PATH + '").new()\n'
    addition += '\t\tif not await probe.run(_game, self, Callable(self, "check")): await finish(); return\n'
    addition += '\t\tawait finish(); return\n'
    entry.write_text(replace_once(text, anchor, addition + anchor), encoding="utf-8")
    if not enabled:
        return
    path = project / "game/raid/raid_authority.gd"
    text = path.read_text(encoding="utf-8")
    old = '\t\t\tif not authority.can_dispatch_phase_callback(callback):\n\t\t\t\tresult_box.append(false)\n\t\t\t\treturn\n\t\t\tresult_box.append(callback.call(authority, phase, tick, intents))'
    new = '\t\t\tvar profile_start := Time.get_ticks_usec()\n'
    new += '\t\t\tvar profile_safe: bool = authority.can_dispatch_phase_callback(callback)\n'
    new += '\t\t\tvar profile_body_start := Time.get_ticks_usec()\n'
    new += '\t\t\tif not profile_safe:\n\t\t\t\tresult_box.append(false)\n\t\t\t\treturn\n'
    new += '\t\t\tvar profile_outcome: Variant = callback.call(authority, phase, tick, intents)\n'
    new += '\t\t\tvar profile_end := Time.get_ticks_usec()\n'
    new += '\t\t\tload("res://' + PROBE_PATH + '").record(authority._processing_handler_id, profile_body_start - profile_start, profile_end - profile_body_start)\n'
    new += '\t\t\tresult_box.append(profile_outcome)'
    path.write_text(replace_once(text, old, new), encoding="utf-8")
    path = project / "game/combat/health_consequence_adapter.gd"
    text = path.read_text(encoding="utf-8")
    for name, signature, args, result_type in (
        ("_audit_actor_state", "actor: Dictionary, tick: int", "actor, tick", "Dictionary"),
        ("_health_state_digest", "actor: Dictionary", "actor", "String"),
        ("_collect_weapon_hits", "tick: int", "tick", "Dictionary"),
        ("_actor_snapshot_from_record", "actor: Dictionary", "actor", "Dictionary"),
    ):
        declaration = f"func {name}({signature}) -> {result_type}:"
        text = replace_once(text, declaration, f"func _profile_original{name}({signature}) -> {result_type}:")
        text += f"\n\n{declaration}\n\tvar start := Time.get_ticks_usec()\n"
        text += f"\tvar result := _profile_original{name}({args})\n"
        text += f'\tload("res://{PROBE_PATH}").detail("health{name}", Time.get_ticks_usec() - start)\n\treturn result\n'
    path.write_text(text, encoding="utf-8")


def execute(command: list[str], env: dict[str, str], timeout: int = 300) -> str:
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end="", flush=True)
    if result.returncode or ERRORS.search(result.stdout):
        raise RuntimeError("Native profiling failed: " + str(command))
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--baseline-ref", help="Git revision supplying the explicitly listed optimized production files")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    engine = str(args.godot.expanduser().resolve(strict=True))
    required = json.loads((source / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
    env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING":"1", "ZERKOV_TEST_SCENARIO":"handler_profile"}
    if execute([engine, "--version"], env).strip() != required:
        raise ValueError("Godot must match the lock")
    checksums = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in [source / "game/raid/raid_authority.gd", source / "game/combat/health_consequence_adapter.gd",
                           source / "game/raid/raid_callback_capture_scanner.gd", source / "game/bootstrap/local/local_game.gd",
                           source / "game/combat/content/zerkov_health_ability_content.gd"]}
    print("RAID_PROFILE_SOURCE " + json.dumps(checksums), flush=True)
    traces = []
    modes = ["baseline", "control", "control", "baseline", "instrumented"] if args.baseline_ref else ["control", "instrumented"]
    optimized = ("game/raid/raid_callback_capture_scanner.gd", "game/combat/content/zerkov_health_ability_content.gd",
                 "game/raid/raid_authority.gd", "game/bootstrap/local/local_raid_session.gd")
    baseline = {}
    if args.baseline_ref:
        revision = subprocess.check_output(["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"], cwd=source, text=True).strip()
        baseline = {name: subprocess.check_output(["git", "show", revision + ":" + name], cwd=source) for name in optimized}
        print("RAID_PROFILE_BASELINE " + json.dumps({"revision":revision, "files":{name:hashlib.sha256(data).hexdigest() for name,data in baseline.items()}}), flush=True)
    for mode in modes:
        enabled = mode == "instrumented"
        print("RAID_PROFILE_MODE " + mode, flush=True)
        with tempfile.TemporaryDirectory(prefix="zerkov-handler-profile-") as temp:
            project = Path(temp) / "project"
            shutil.copytree(source, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
            if mode == "baseline":
                for name, data in baseline.items(): (project / name).write_bytes(data)
            instrument(project, enabled)
            env["XDG_DATA_HOME"] = str(Path(temp) / "userdata")
            base = [engine, "--headless", "--path", str(project), "--resolution", "1920x1080", "--audio-driver", "Dummy"]
            execute(base + ["--editor", "--import", "--quit"], env)
            script = base + ["--script", "res://tests/local/native_local_flow_contract.gd", "--"]
            namespace = "localflow_" + uuid.uuid4().hex
            try:
                output = execute(script + ["run", namespace], env)
                if not re.search(r"(?m)^NATIVE_LOCAL_FLOW_RESULT checks=[1-9][0-9]* failures=0$", output):
                    raise RuntimeError("Missing native success marker")
                match = re.search(r"(?m)^RAID_PROFILE_DIGESTS (.+)$", output)
                if not match:
                    raise RuntimeError("Missing authority trace")
                traces.append(json.loads(match[1]))
            finally:
                execute(script + ["cleanup", namespace], env)
    if any(trace != traces[0] for trace in traces):
        raise RuntimeError("Baseline, candidate or instrumentation changed the authoritative trace")
    for name, digest in checksums.items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError("Original checkout changed during profiling")
    print("RAID_PROFILE_COMPLETE control_matches_instrumented=true original_checkout_unchanged=true baseline_matches_candidate=" + ("true" if args.baseline_ref else "not_run"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
