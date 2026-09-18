extends SceneTree
## Detached presentation values only. Actual combat/input proof lives in the
## application driver; this test never claims its synthetic frames are gameplay.
var checks: int = 0
var failures: int = 0
var view: LocalWeaponPresenter

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("WEAPON_PRESENTATION: " + label)

func frame(tick: int) -> Dictionary:
	return {"generation": 7, "actor_id": "presentation-test-player", "tick": tick,
		"health": {"alive": true}, "weapon": {"instance_id": "same-akm-instance", "definition_id": LocalWeaponPresenter.AKM,
			"phase": "ready", "loaded_rounds": 29},
		"melee_equipment": {"weapon_id": "same-machete-instance", "definition_id": LocalWeaponPresenter.MACHETE},
		"melee": {"phase": &"ready"}, "feedback": [], "receipts": []}

func shot(tick: int, id: String = "committed-shot-1") -> Dictionary:
	return {"id": id, "kind": &"shot", "actor_id": "presentation-test-player", "tick": tick,
		"weapon_instance_id": "same-akm-instance", "weapon_id": LocalWeaponPresenter.AKM,
		"origin_raw": Vector2i(1_000_000, 1_000_000), "target_raw": Vector2i(3_000_000, 1_000_000),
		"hit": true, "blocked": false, "damage_confirmed": true}

func present(value: Dictionary, facing: Vector2 = Vector2.RIGHT) -> bool:
	ZMeleeTimeline._freeze(value)
	return view.present(Vector2(32, 32), facing, value)

func run() -> void:
	var rejected := LocalWeaponPresenter.new(); root.add_child(rejected)
	check(not rejected.configure(0) and rejected._sprite == null, "invalid configure allocates no unowned sprites")
	rejected.release(); rejected.queue_free(); await process_frame
	view = LocalWeaponPresenter.new(); root.add_child(view)
	check(view.configure(7), "single generation configured")
	check(not view.configure(7), "cannot configure twice")
	var first := frame(1)
	check(present(first), "canonical primary sample")
	check(view.snapshot().is_read_only(), "read-only diagnostic projection")
	check(view.snapshot().visible and view.snapshot().held_instance_id == "same-akm-instance", "canonical firearm identity visible")
	check(view._sprite.texture == view.akm_texture, "actual shipped AKM texture assigned to sprite")
	check(present(first) and view.snapshot().shot_count == 0, "identical sample is idempotent")
	var changed := frame(1); changed.weapon.instance_id = "different"
	check(not present(changed) and view.snapshot().held_instance_id == "same-akm-instance", "same-tick conflict cannot change gear")
	var bad := frame(2); bad.generation = 8
	check(not present(bad), "wrong generation rejected")
	bad = frame(2); bad.actor_id = "other"
	check(not present(bad), "another actor cannot hijack binding")
	bad = frame(2); bad.feedback = [17]
	check(not present(bad), "malformed feedback safely rejected")
	bad = frame(2); bad.weapon.erase("instance_id")
	check(not present(bad), "malformed primary rejected without partial visibility change")
	var fired := frame(2); fired.feedback = [shot(2), shot(2)]
	check(present(fired), "committed shot rendered")
	check(view.snapshot().shot_count == 1 and view.snapshot().effect_count == 1, "duplicate consequence in frame plays once")
	check(view._effects[0].event.target_raw == shot(2).target_raw, "actual collision endpoint retained")
	check(present(fired) and view.snapshot().shot_count == 1, "re-presenting closed tick cannot replay flash")
	check(not present(first) and view.snapshot().shot_count == 1, "stale frame cannot replay or roll back")
	var replay := frame(3); replay.feedback = [shot(3)]
	check(present(replay) and view.snapshot().shot_count == 1, "reused consequence identity cannot replay on a later tick")
	var invalid := frame(4)
	for key: String in ["actor_id", "weapon_instance_id", "weapon_id", "tick", "target_raw"]:
		var event := shot(4, "invalid-" + key)
		event[key] = 3 if key == "tick" else (Vector2i(2_147_000_000, 0) if key == "target_raw" else "wrong")
		invalid.feedback.append(event)
	check(present(invalid) and view.snapshot().shot_count == 1, "foreign, stale, unmapped and out-of-bounds events make no shot")
	check(present(frame(8), Vector2.LEFT) and view.snapshot().effect_count == 0, "effects expire on canonical tick")
	check(is_equal_approx(absf(view._sprite.rotation), PI) and view._sprite.scale.y < 0.0, "left-facing gun follows aim without upside-down artwork")
	var dry := frame(9); dry.weapon.loaded_rounds = 0
	dry.receipts = [{"kind": &"fire", "committed": false}]
	check(present(dry) and view.snapshot().shot_count == 1 and view.snapshot().effect_count == 0, "dry/rejected trigger cannot create successful feedback")
	var reload := frame(10); reload.weapon.phase = "reloading"; reload.weapon.reload = {"start_tick": 10, "due_tick": 20}
	check(present(reload) and view.snapshot().reloading and view.snapshot().reload_progress == 0.0, "reload begins from native due fields")
	reload = frame(15); reload.weapon.phase = "reloading"; reload.weapon.reload = {"start_tick": 10, "due_tick": 20}
	check(present(reload) and view.snapshot().reload_progress == 0.5, "reload progress uses committed tick, not render delta")
	check(present(frame(20)) and not view.snapshot().reloading, "completed reload retires cosmetic bar")
	var swing := frame(21); swing.melee = {"phase": &"active", "swing": {"start_tick": 20, "ready_tick": 30}}
	check(present(swing), "committed melee timeline displayed")
	check(view.snapshot().held_definition == LocalWeaponPresenter.MACHETE and view.snapshot().primary_instance_id == "same-akm-instance", "temporary machete does not overwrite primary identity")
	check(present(frame(30)) and view.snapshot().held_instance_id == "same-akm-instance", "melee recovery restores firearm")
	var empty := frame(31); empty.weapon = {}
	check(present(empty) and view.snapshot().held_instance_id == "same-machete-instance", "unequipped primary falls back only to actual equipped machete")
	check(view._sprite.texture == view.machete_texture, "machete uses its own original art")
	empty = frame(32); empty.weapon = {}; empty.melee_equipment = {}
	check(present(empty) and not view.snapshot().visible and view._sprite.texture == null, "fully empty hands have no fixture gear")
	var unknown := frame(33); unknown.weapon.definition_id = "unsupported.weapon"
	check(present(unknown) and not view.snapshot().visible, "unsupported definition never substitutes AKM")
	var last_shot := frame(34); last_shot.feedback = [shot(34, "shot-before-death")]
	check(present(last_shot) and view.snapshot().effect_count == 1, "re-equipped same instance can fire again")
	var dead := frame(35); dead.health.alive = false
	check(present(dead) and not view.snapshot().visible and view.snapshot().effect_count == 0, "death clears held art and all effects")
	check(not present(frame(36)), "dead binding cannot resurrect from a stale live sample")
	view.release()
	check(view.snapshot().is_empty() and not view._sprite.visible, "release clears immutable view and sprite")
	check(not present(frame(37)) and not view.configure(8), "released binding cannot accept any generation")
	view.queue_free(); await process_frame
	view = LocalWeaponPresenter.new(); root.add_child(view); view.akm_texture = null
	check(view.configure(7), "missing art is a usable but invisible presentation binding")
	fired = frame(1); fired.feedback = [shot(1)]
	check(present(fired) and not view.snapshot().visible and view.snapshot().effect_count == 0, "missing art is not substituted and cannot retain muzzle FX")
	view.release(); view.queue_free(); await process_frame
	await actor_contract()
	print("WEAPON_PRESENTATION_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

func actor_contract() -> void:
	var actor := LocalActorPresenter.new(); root.add_child(actor)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://game/content/art/local_player_manifest.json"))
	var textures: Dictionary = {}
	for key: String in manifest.sources: textures[key] = load(manifest.sources[key].path)
	check(actor.configure(manifest, textures, 7), "actual layered actor binds weapon presenter")
	var value := frame(1); value.receipts = [{"kind": &"melee", "committed": true}]
	ZMeleeTimeline._freeze(value)
	check(actor.present(Vector2.ZERO, Vector2.ZERO, Vector2.RIGHT, value), "actual actor consumes committed melee sample")
	var sequence: int = actor._sequence
	check(actor.present(Vector2.ZERO, Vector2.ZERO, Vector2.RIGHT, value) and actor._sequence == sequence, "same frame cannot restart body melee animation")
	actor.release(); actor.queue_free(); await process_frame
