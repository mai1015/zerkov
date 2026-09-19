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
	check(view._sprite.texture == view.akm_art.texture, "actual shipped AKM texture assigned to sprite")
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
	check(present(frame(8), Vector2.LEFT) and view.snapshot().effect_count == 1, "original multi-frame FX remains alive within its authored tick duration")
	check(is_equal_approx(absf(view._sprite.rotation), PI) and view._sprite.scale.y < 0.0, "left-facing gun follows aim without upside-down artwork")
	var dry := frame(9); dry.weapon.loaded_rounds = 0
	dry.receipts = [{"kind": &"fire", "committed": false}]
	check(present(dry) and view.snapshot().shot_count == 1 and view.snapshot().effect_count == 1, "dry/rejected trigger cannot create additional successful feedback")
	var reload := frame(10); reload.weapon.phase = "reloading"; reload.weapon.reload = {"start_tick": 10, "due_tick": 20}
	check(present(reload) and view.snapshot().reloading and view.snapshot().reload_progress == 0.0, "reload begins from native due fields")
	reload = frame(15); reload.weapon.phase = "reloading"; reload.weapon.reload = {"start_tick": 10, "due_tick": 20}
	check(present(reload) and view.snapshot().reload_progress == 0.5, "reload progress uses committed tick, not render delta")
	check(present(frame(20)) and not view.snapshot().reloading, "completed reload retires cosmetic bar")
	var swing := frame(21); swing.melee = {"phase": &"active", "swing": {"start_tick": 20, "ready_tick": 30}}
	check(present(swing), "committed melee timeline displayed")
	check(view.snapshot().held_definition == LocalWeaponPresenter.MACHETE and view.snapshot().primary_instance_id == "same-akm-instance", "temporary machete does not overwrite primary identity")
	check(present(frame(30)) and view.snapshot().held_instance_id == "same-akm-instance" and view.snapshot().effect_count == 0, "melee recovery restores firearm and prior source FX expires")
	var empty := frame(31); empty.weapon = {}
	check(present(empty) and view.snapshot().held_instance_id == "same-machete-instance", "unequipped primary falls back only to actual equipped machete")
	check(view._sprite.texture == view.machete_art.texture, "machete uses its own original art")
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
	view = LocalWeaponPresenter.new(); root.add_child(view); view.akm_art = view.akm_art.duplicate(); view.akm_art.texture = null
	check(view.configure(7), "missing art is a usable but invisible presentation binding")
	fired = frame(1); fired.feedback = [shot(1)]
	check(present(fired) and not view.snapshot().visible and view.snapshot().effect_count == 0, "missing art is not substituted and cannot retain muzzle FX")
	view.release(); view.queue_free(); await process_frame
	await source_fx_contract()
	await actor_contract()
	await attachment_contract()
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
	check(not actor._layers._layers[2].visible and actor._weapon.snapshot().arms_overridden, "original combined AK arms replace dangling body arms")
	check(actor._layers._layers[0].scale.x == -1.0, "source-left main character mirrors with right-facing holding pose")
	var attack := frame(2)
	attack.melee = {"phase": &"active", "swing": {"start_tick": 1, "active_tick": 2, "recovery_tick": 5, "ready_tick": 23, "aim_raw": Vector2i(-1000000, 0)}}
	ZMeleeTimeline._freeze(attack)
	check(actor.present(Vector2.ZERO, Vector2.ZERO, Vector2.LEFT, attack), "real layered actor samples source melee pose")
	check(actor._weapon.snapshot().attack_frame == 3 and actor._layers._layers[2].visible and not actor._weapon.snapshot().arms_overridden, "original attack arm frame and blade frame share canonical active window")
	for index in range(4):
		check(actor._layers._layers[index].region_rect.position.x == 192.0, "body part uses source attack frame 3")
	check(actor._weapon._sprite.texture == actor._weapon.machete_art.attack_frames.get_frame_texture(&"attack", 3), "approved Option A uses original registered knife strip during attack")
	var empty := frame(24); empty.weapon = {}; empty.melee_equipment = {}; ZMeleeTimeline._freeze(empty)
	check(actor.present(Vector2.ZERO, Vector2.ZERO, Vector2.LEFT, empty) and actor._layers._layers[2].visible and not actor._weapon._sprite.visible, "empty hands restore original idle arms")
	actor.release(); actor.queue_free(); await process_frame

func source_fx_contract() -> void:
	var fx := LocalWeaponPresenter.FX
	for name: StringName in [&"muzzle", &"wood", &"metal", &"concrete", &"brick", &"dust"]:
		check(fx.has_animation(name) and not fx.get_animation_loop(name), "native one-shot source effect exists: " + name)
		check(fx.get_frame_count(name) == (7 if name == &"muzzle" else 8), "exact authored frame count: " + name)
		for i in range(fx.get_frame_count(name)):
			var texture := fx.get_frame_texture(name, i) as AtlasTexture
			check(texture != null and texture.atlas.resource_path.begins_with("res://assets/original/fx/") and texture.filter_clip,
				"effect frame directly references original sheet with edge clipping")
	view = LocalWeaponPresenter.new(); root.add_child(view)
	check(view.configure(7, {"wall": "wood"}), "explicit visual-only material map")
	var value := frame(1); var event := shot(1, "blocked-source-fx")
	event.hit = false; event.blocked = true; event.obstruction_id = "wall"; event.damage_confirmed = false
	value.feedback = [event]; check(present(value), "confirmed blocked shot sampled")
	check(view._effects[0].surface == "wood", "only explicit hit obstruction chooses wood source FX")
	var muzzle: Vector2 = Vector2(32, 32) + view._sprite.transform * (view.akm_art.muzzle - view.akm_art.grip)
	check((Vector2(32, 32) + view._muzzle.global_position).is_equal_approx(muzzle), "gun-local emitter uses source barrel, not inventory offset")
	value = frame(2); event = shot(2, "unknown-source-fx"); event.hit = false; event.blocked = true; event.obstruction_id = "unknown"; value.feedback = [event]
	check(present(value) and view._effects[1].surface.is_empty(), "unknown obstruction cannot invent material-specific impact")
	value = frame(3); event = shot(3, "clear-source-fx"); event.hit = false; event.blocked = false; event.obstruction_id = "wall"; value.feedback = [event]
	check(present(value) and view._effects[2].surface.is_empty(), "clear miss cannot use a stale surface mapping")
	check(present(frame(27)) and view.snapshot().effect_count == 0, "all source FX retire on canonical deadline")
	check(LocalWeaponPresenter.BLOOD.size() == 9, "all nine supplied blood particles available")
	for i in range(9):
		check(LocalWeaponPresenter.BLOOD[i].resource_path.begins_with("res://assets/original/fx/blood particles/"), "blood is an original texture, not a drawn hit cross")
	view.release(); view.queue_free(); await process_frame

func attachment_contract() -> void:
	# A transformed ancestor exposes accidental mixing of local/world positions.
	var parent := Node2D.new()
	parent.position = Vector2(81, 46); parent.rotation = 0.17; parent.scale = Vector2(2, 2)
	root.add_child(parent)
	var actor := LocalActorPresenter.new(); parent.add_child(actor)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://game/content/art/local_player_manifest.json"))
	var textures: Dictionary = {}
	for key: String in manifest.sources: textures[key] = load(manifest.sources[key].path)
	check(actor.configure(manifest, textures, 7), "attachment regression binds actual layered actor")
	var value := frame(1); value.feedback = [shot(1, "attachment-shot")]; ZMeleeTimeline._freeze(value)
	check(actor.present(Vector2(32, 48), Vector2.ZERO, Vector2.RIGHT, value), "shot binds muzzle to held gun")
	var weapon: LocalWeaponPresenter = actor._weapon
	check(weapon._muzzle.get_parent() == weapon._sprite, "muzzle is a gun child, not a shot-world marker")
	var original_target: Vector2i = weapon._effects[0].event.target_raw
	var old_muzzle: Vector2 = weapon._muzzle.global_position
	for i in range(4):
		var aim: Vector2 = [Vector2.RIGHT, Vector2.LEFT, Vector2(1,-1).normalized(), Vector2(-1,1).normalized()][i]
		value = frame(2 + i); ZMeleeTimeline._freeze(value)
		check(actor.present(Vector2(42 + i*7, 51 + i*3), Vector2(1, 0), aim, value), "move/turn accepted during existing flash")
		var expected: Vector2 = weapon._sprite.to_global(weapon.akm_art.muzzle - weapon.akm_art.grip)
		check(weapon._muzzle.visible and weapon._muzzle.global_position.is_equal_approx(expected), "live emitter follows translated/rotated/mirrored source barrel")
		check(not weapon._muzzle.global_position.is_equal_approx(old_muzzle), "muzzle is not stranded at old shot position")
		check(weapon._effects[0].event.target_raw == original_target and weapon.snapshot().shot_count == 1, "moving muzzle does not move impact or invent shots")
		check(weapon._muzzle.global_transform.x.is_equal_approx(weapon._sprite.global_transform.x), "flash inherits gun orientation and scale exactly")
		old_muzzle = weapon._muzzle.global_position
	value = frame(6); value.weapon.phase = "reloading"; value.weapon.reload = {"start_tick":6,"due_tick":8}; ZMeleeTimeline._freeze(value)
	check(actor.present(Vector2(70, 70), Vector2.ZERO, Vector2.RIGHT, value) and not weapon._muzzle.visible, "reload hides old muzzle flash")
	# All six source frames in both directions. Body and blade are already
	# authored poses, so oblique aim cannot independently rotate the blade.
	var tick: int = 10
	for left: bool in [true, false]:
		var start: int = tick
		for index in range(6):
			var offsets: Array[int] = [0, 4, 7, 10, 13, 22]
			tick = start + offsets[index]
			value = frame(tick)
			var aim := Vector2i(-1000000 if left else 1000000, 250000)
			value.melee = {"phase": &"windup" if index < 3 else (&"active" if index == 3 else &"recovery"),
				"swing": {"start_tick": start, "active_tick": start+10, "recovery_tick": start+13, "ready_tick": start+31, "aim_raw": aim}}
			ZMeleeTimeline._freeze(value)
			check(actor.present(Vector2(70, 70), Vector2.ZERO, Vector2(aim).normalized(), value), "source knife frame accepted")
			var arms: Sprite2D = actor._layers._layers[2]
			var blade: Sprite2D = weapon._sprite
			check(weapon.snapshot().authored_attack and weapon.snapshot().attack_frame == index, "knife uses shared committed six-frame sampling")
			check(arms.visible and not weapon.snapshot().arms_overridden, "original attack hands remain visible exactly once")
			check(blade.transform.is_equal_approx(arms.transform) and blade.offset == Vector2.ZERO, "blade and hands share full canvas transform, not inventory offsets")
			check(blade.scale.abs() == Vector2.ONE and blade.rotation == 0.0, "native-scale knife is not rotated separately from painted hand")
			var atlas := blade.texture as AtlasTexture
			check(atlas != null and atlas.region == Rect2(index*64, 0, 64, 64) and atlas.atlas.resource_path.ends_with("/knife-attack-knife.png"), "exact original source cell used")
			check(arms.region_rect == atlas.region and not weapon._muzzle.visible, "hand/knife frame indices match and rifle flash stays hidden")
		tick = start + 32
		value = frame(tick); ZMeleeTimeline._freeze(value)
		check(actor.present(Vector2(70,70), Vector2.ZERO, Vector2.LEFT if left else Vector2.RIGHT, value), "recovery restores ordinary equipment")
		check(weapon._sprite.texture == weapon.akm_art.texture and not weapon.snapshot().authored_attack, "attack strip does not linger after recovery")
		tick += 1
	value = frame(tick+1); value.weapon = {}; value.melee_equipment = {}; ZMeleeTimeline._freeze(value)
	check(actor.present(Vector2.ZERO,Vector2.ZERO,Vector2.RIGHT,value) and not weapon._sprite.visible and not weapon._muzzle.visible, "empty hands clear blade and muzzle")
	actor.release(); check(weapon._muzzle.texture == null, "release clears muzzle resource")
	parent.queue_free(); await process_frame
