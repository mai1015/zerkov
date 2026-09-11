extends SceneTree
## Run with: Godot --headless --path . --audio-driver Dummy \
##   --script res://tests/ai/vision_world_contract.gd
##
## Production observer/target lifecycle remains task 6.2.  This contract places
## direct native fixtures only to prove the task-6.1 world configuration,
## cadence, memory input, scheduler budget, and telemetry boundaries.

const Config = preload("res://game/ai/vision/zerkov_vision_config.gd")
const VisionOwner = preload("res://game/ai/vision/raid_vision_world_owner.gd")
const WorldUnits = preload("res://game/domain/z_world_units.gd")

const STATUS_NOT_FOUND: int = 2
const STATE_UNKNOWN: int = 0
const STATE_REMEMBERED: int = 1
const STATE_VISIBLE: int = 2
const TRANSITION_BECAME_VISIBLE: int = 1
const TRANSITION_BECAME_REMEMBERED: int = 3
const TRANSITION_REMAINED_REMEMBERED: int = 4
const TRANSITION_MEMORY_EXPIRED: int = 5

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("VISION_WORLD_CONTRACT: " + message)


func run() -> void:
	_test_sealed_configuration_and_provenance()
	_test_units_masks_ranges_cones_and_samples()
	await _test_owner_configuration_and_lifecycle()
	await _test_cadence_memory_and_render_independence()
	_test_budget_defer_and_deterministic_telemetry()
	_test_raid_phase_driver()
	print("VISION_CONFIG_FINGERPRINT=", Config.fingerprint(Config.configuration()))
	print("VISION_WORLD_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_sealed_configuration_and_provenance() -> void:
	var configuration: Dictionary = Config.configuration()
	var semantic := Config.validate_configuration(configuration, false)
	check(bool(semantic.get("ok", false)), "fixed configuration passes semantic validation")
	var sealed := Config.validate_configuration(configuration, true)
	check(bool(sealed.get("ok", false)), "fixed configuration matches its checked-in seal")
	check(String(sealed.get("fingerprint", "")).length() == 64,
		"configuration seal is a SHA-256 fingerprint")
	check(Config.fingerprint(configuration) == Config.fingerprint(Config.configuration()),
		"fresh configuration records have the same stable fingerprint")

	var preflight := Config.runtime_preflight()
	check(bool(preflight.get("ok", false)), "installed Common Vision provenance is accepted")
	check(String(preflight.get("api_version", "")) == Config.EXPECTED_API_VERSION,
		"runtime API matches the sealed API")
	check(int(preflight.get("protocol_version", 0)) == Config.EXPECTED_PROTOCOL_VERSION,
		"runtime protocol matches the sealed protocol")
	check(int(preflight.get("algorithm_contract", 0))
		== Config.EXPECTED_ALGORITHM_CONTRACT,
		"runtime algorithm contract matches the sealed algorithm")
	check(int(preflight.get("coordinate_scale", 0)) == Config.EXPECTED_COORDINATE_SCALE,
		"runtime coordinate scale matches ZWorldUnits")
	check(int(preflight.get("supported_features", 0)) & Config.REQUIRED_FEATURES
		== Config.REQUIRED_FEATURES,
		"runtime exposes fixed LOS, memory, and budget scheduling")

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(Config.ADDON_LOCK_PATH))
	check(parsed is Dictionary, "project add-on lock parses")
	if parsed is Dictionary:
		var locked := Config.validate_lock_document(parsed as Dictionary, true)
		check(bool(locked.get("ok", false)), "exact installed lock and artifacts validate")
		var duplicate_lock := (parsed as Dictionary).duplicate(true)
		var duplicate_addons := duplicate_lock["addons"] as Array
		for entry_value in duplicate_addons.duplicate(true):
			var entry := entry_value as Dictionary
			if String(entry.get("id", "")) == Config.ADDON_ID:
				duplicate_addons.append(entry.duplicate(true))
				break
		var duplicate_result := Config.validate_lock_document(duplicate_lock)
		check(not bool(duplicate_result.get("ok", true))
			and duplicate_result.get("reason") == &"common_vision_lock_duplicate",
			"duplicate Common Vision provenance is rejected")

		var wrong_provenance := (parsed as Dictionary).duplicate(true)
		for entry_value in wrong_provenance["addons"] as Array:
			var entry := entry_value as Dictionary
			if String(entry.get("id", "")) == Config.ADDON_ID:
				(entry["source"] as Dictionary)["package_tree_sha256"] = "0".repeat(64)
		var provenance_result := Config.validate_lock_document(wrong_provenance)
		check(not bool(provenance_result.get("ok", true))
			and provenance_result.get("reason")
				== &"common_vision_lock_provenance_incompatible",
			"mismatched package provenance fails closed")

	var tampered := configuration.duplicate(true)
	(tampered["observer_profiles"] as Array)[0]["memory_ticks"] = 181
	var tampered_result := Config.validate_configuration(tampered, true)
	check(not bool(tampered_result.get("ok", true))
		and tampered_result.get("reason") == &"configuration_fingerprint_mismatch",
		"semantically valid but unsealed configuration is rejected")

	var bad_provenance := configuration.duplicate(true)
	(bad_provenance["provenance"] as Dictionary)["api_version"] = "0.2.0"
	var bad_provenance_result := Config.validate_configuration(bad_provenance, false)
	check(not bool(bad_provenance_result.get("ok", true))
		and bad_provenance_result.get("reason")
			== &"configuration_provenance_incompatible",
		"configuration with incompatible API provenance is rejected")

	var duplicate_profile := configuration.duplicate(true)
	var observer_profiles := duplicate_profile["observer_profiles"] as Array
	observer_profiles.append((observer_profiles[0] as Dictionary).duplicate(true))
	var duplicate_profile_result := Config.validate_configuration(duplicate_profile, false)
	check(not bool(duplicate_profile_result.get("ok", true))
		and duplicate_profile_result.get("reason") == &"observer_profile_duplicate",
		"duplicate observer configuration is rejected")


func _test_units_masks_ranges_cones_and_samples() -> void:
	check(WorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT == Config.EXPECTED_COORDINATE_SCALE,
		"ZWorldUnits is the sole Common Vision coordinate scale")
	var one_tile := WorldUnits.godot_to_vision(Vector2(32.0, -32.0))
	check(one_tile.ok and one_tile.vector2i_value == Vector2i(1_000_000, -1_000_000),
		"one 32 px source tile converts to one Vision world unit")
	var restored_tile := WorldUnits.vision_to_godot(one_tile.vector2i_value)
	check(restored_tile.ok and restored_tile.vector2_value == Vector2(32.0, -32.0),
		"Vision tile coordinates round-trip through ZWorldUnits")
	var sample_raw := Vector2i(0, Config.MAX_SAMPLE_OFFSET_RAW)
	var sample_px := WorldUnits.vision_to_godot(sample_raw)
	check(sample_px.ok and sample_px.vector2_value == Vector2(0.0, 8.0),
		"quarter-tile target sample converts to exactly eight Godot pixels")
	var restored_sample := WorldUnits.godot_to_vision(sample_px.vector2_value)
	check(restored_sample.ok and restored_sample.vector2i_value == sample_raw,
		"target sample offset round-trips without a second quantizer")
	var maximum_range_px := WorldUnits.vision_to_godot(
		Vector2i(Config.MAX_PROFILE_RANGE_RAW, 0)
	)
	check(maximum_range_px.ok and maximum_range_px.vector2_value.x == 576.0,
		"sealed 18-tile maximum sight range is 576 Godot pixels")

	check(Config.TARGET_LAYER_PLAYER == 1 and Config.TARGET_LAYER_SCAV == 2
		and Config.TARGET_LAYER_MUTANT == 4,
		"actor target masks are explicit disjoint bits")
	check(Config.TARGET_LAYER_HOSTILE == 6 and Config.TARGET_LAYER_ALL_ACTORS == 7,
		"composed actor target masks are exact")
	check(Config.OCCLUDER_LAYER_STRUCTURE == 1
		and Config.OCCLUDER_LAYER_VEGETATION == 2
		and Config.OCCLUDER_LAYER_ALL == 3,
		"structure and vegetation occluder masks are explicit")

	var scav := Config.observer_profile(Config.OBSERVER_PROFILE_SCAV)
	var mutant := Config.observer_profile(Config.OBSERVER_PROFILE_MUTANT)
	check(int(scav.get("range_raw", 0)) == 18_000_000
		and int(scav.get("cone_cos_million", 0)) == 500_000
		and int(scav.get("memory_ticks", 0)) == 180,
		"Scav range, 120-degree cone, and three-second memory are exact")
	check(int(mutant.get("range_raw", 0)) == 12_000_000
		and int(mutant.get("cone_cos_million", 0)) == 173_648
		and int(mutant.get("memory_ticks", 0)) == 120,
		"mutant range, 160-degree cone, and two-second memory are exact")
	check(bool(scav.get("urgent", false)) and int(scav.get("priority", 0)) == 200
		and not bool(mutant.get("urgent", true))
		and int(mutant.get("priority", 0)) == 100,
		"scheduler class and priority are explicit and deterministic")

	var player_target := Config.target_profile(Config.TARGET_PROFILE_PLAYER)
	var samples := player_target.get("sample_offsets", []) as Array
	check(int(player_target.get("mask", 0)) == Config.TARGET_LAYER_PLAYER
		and int(player_target.get("sample_policy", -1)) == Config.SAMPLE_POLICY_ANY,
		"player target mask and ANY_SAMPLE policy are explicit")
	check(samples.size() == Config.MAX_TARGET_SAMPLES
		and Config.MAX_TARGET_SAMPLES < Config.NATIVE_MAX_SAMPLES,
		"three actor samples stay below the native eight-sample cap")
	check(samples == [
		{"x": 0, "y": 0},
		{"x": 0, "y": -250_000},
		{"x": 0, "y": 250_000},
	], "center and quarter-tile samples are exact and ordered")

	var valid_boundary := Config.configuration()
	(valid_boundary["observer_profiles"] as Array)[0]["cone_cos_million"] = 0
	(valid_boundary["observer_profiles"] as Array)[0]["memory_ticks"] = Config.MAX_MEMORY_TICKS
	check(bool(Config.validate_configuration(valid_boundary, false).get("ok", false)),
		"documented zero cone cosine and game memory maximum are valid bounds")
	var bad_range := Config.configuration()
	(bad_range["observer_profiles"] as Array)[0]["range_raw"] = 0
	check(Config.validate_configuration(bad_range, false).get("reason")
		== &"observer_range_invalid", "zero observer range is rejected")
	var excessive_range := Config.configuration()
	(excessive_range["observer_profiles"] as Array)[0]["range_raw"] \
		= Config.MAX_PROFILE_RANGE_RAW + 1
	check(Config.validate_configuration(excessive_range, false).get("reason")
		== &"observer_range_invalid", "observer range above the sealed bound is rejected")
	var bad_cone := Config.configuration()
	(bad_cone["observer_profiles"] as Array)[0]["cone_cos_million"] \
		= Config.CONE_COS_SCALE + 1
	check(Config.validate_configuration(bad_cone, false).get("reason")
		== &"observer_cone_invalid", "cone cosine above the documented scale is rejected")
	var bad_memory := Config.configuration()
	(bad_memory["observer_profiles"] as Array)[0]["memory_ticks"] \
		= Config.MAX_MEMORY_TICKS + 1
	check(Config.validate_configuration(bad_memory, false).get("reason")
		== &"observer_memory_invalid", "memory above the game bound is rejected")
	var bad_mask := Config.configuration()
	(bad_mask["target_profiles"] as Array)[0]["mask"] = 0
	check(Config.validate_configuration(bad_mask, false).get("reason")
		== &"target_mask_invalid", "zero target mask is rejected")
	var too_many_samples := Config.configuration()
	var too_many_offsets := (too_many_samples["target_profiles"] as Array)[0][
		"sample_offsets"
	] as Array
	too_many_offsets.append({"x": 250_000, "y": 0})
	check(Config.validate_configuration(too_many_samples, false).get("reason")
		== &"target_sample_count_invalid", "a fourth production target sample is rejected")
	var bad_sample := Config.configuration()
	((bad_sample["target_profiles"] as Array)[0]["sample_offsets"] as Array)[1]["y"] \
		= Config.MAX_SAMPLE_OFFSET_RAW + 1
	check(Config.validate_configuration(bad_sample, false).get("reason")
		== &"target_sample_out_of_range", "sample outside the quarter-tile bound is rejected")
	var bad_cadence := Config.configuration()
	(bad_cadence["schedule"] as Dictionary)["cadence_interval_ticks"] = 7
	check(Config.validate_configuration(bad_cadence, false).get("reason")
		== &"vision_cadence_invalid", "cadence not dividing the 60 Hz clock is rejected")
	var bad_budget := Config.configuration()
	(bad_budget["schedule"] as Dictionary)["work_budget_per_evaluation"] \
		= Config.NATIVE_MAX_WORK_UNITS + 1
	check(Config.validate_configuration(bad_budget, false).get("reason")
		== &"vision_work_budget_invalid", "budget above native hard limit is rejected")


func _test_owner_configuration_and_lifecycle() -> void:
	var invalid_owner := VisionOwner.new()
	root.add_child(invalid_owner)
	check(not invalid_owner.configure(0)
		and invalid_owner.last_error == &"vision_world_id_invalid",
		"owner rejects a non-positive world identity")
	check(invalid_owner.get_child_count() == 0 and invalid_owner.generation() == 0,
		"invalid identity creates no partial native world")
	var tampered := Config.configuration()
	(tampered["schedule"] as Dictionary)["work_budget_per_evaluation"] -= 1
	check(not invalid_owner.configure(6_101, tampered)
		and invalid_owner.last_error == &"configuration_fingerprint_mismatch",
		"owner rejects an unsealed work budget")
	check(invalid_owner.get_child_count() == 0,
		"invalid configuration remains fail-atomic and retryable")
	check(invalid_owner.configure(6_101), "owner accepts the exact sealed configuration")
	var generation := invalid_owner.generation()
	var native_world := invalid_owner.authority_world(generation)
	check(generation == 1 and native_world != null
		and native_world.get_parent() == invalid_owner,
		"owner creates one scene-owned native authority child")
	var native_instance_id := native_world.get_instance_id()
	var receipt := invalid_owner.configuration_receipt()
	check(receipt.is_read_only() and bool(receipt.get("active", false))
		and receipt.get("configuration_fingerprint") == Config.SEALED_FINGERPRINT,
		"configuration receipt is immutable and carries the exact seal")
	check(not invalid_owner.configure(6_102)
		and invalid_owner.last_error == &"owner_already_configured",
		"duplicate owner configuration is rejected")
	check(invalid_owner.authority_world(generation).get_instance_id() == native_instance_id
		and invalid_owner.world_id() == 6_101 and invalid_owner.generation() == generation,
		"duplicate configuration cannot reset accepted native state")
	check(not invalid_owner.advance_authority_tick(2, generation)
		and invalid_owner.last_error == &"vision_tick_regressed_or_skipped",
		"skipping the first authority tick fails closed")
	check(invalid_owner.advance_authority_tick(1, generation),
		"direct focused driver advances the exact first tick before raid registration")
	check(not invalid_owner.advance_authority_tick(2, generation + 1)
		and invalid_owner.last_error == &"stale_generation",
		"stale owner generation cannot advance Vision")
	check(not invalid_owner.teardown(generation + 1)
		and invalid_owner.last_error == &"stale_generation",
		"stale generation cannot tear down Vision")
	var native_weak: WeakRef = weakref(native_world)
	check(invalid_owner.teardown(generation), "exact generation tears down Vision")
	check(invalid_owner.lifecycle == VisionOwner.Lifecycle.TORN_DOWN
		and invalid_owner.generation() == generation + 1
		and invalid_owner.authority_world(generation) == null,
		"teardown invalidates generation and native access immediately")
	check(not invalid_owner.advance_authority_tick(2, generation)
		and invalid_owner.last_error == &"stale_generation",
		"late tick cannot mutate a torn-down generation")
	check(not invalid_owner.teardown(generation), "teardown cannot replay")
	await process_frame
	check(native_weak.get_ref() == null, "native authority node is released after teardown")
	invalid_owner.queue_free()

	var tree_owner := VisionOwner.new()
	root.add_child(tree_owner)
	check(tree_owner.configure(6_102), "tree-lifecycle owner configures")
	var tree_native_weak: WeakRef = weakref(
		tree_owner.authority_world(tree_owner.generation())
	)
	tree_owner.queue_free()
	await process_frame
	check(tree_native_weak.get_ref() == null,
		"scene-tree removal releases the native authority child")


func _test_cadence_memory_and_render_independence() -> void:
	var owner := VisionOwner.new()
	root.add_child(owner)
	check(owner.configure(6_103), "cadence fixture owner configures")
	var generation := owner.generation()
	var world := owner.authority_world(generation)
	check(world != null, "cadence fixture obtains generation-checked native world")
	if world == null:
		owner.queue_free()
		return

	check(_native_ok(world.register_observer(_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 101, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))), "cadence fixture observer registers through documented native API")
	var target_definition := _target_definition(
		Config.TARGET_PROFILE_PLAYER,
		201,
		Vector2i(4_000_000, 0)
	)
	check(_native_ok(world.register_target(target_definition)),
		"cadence fixture target registers through documented native API")

	var before_frames := owner.telemetry_fingerprint()
	await process_frame
	await process_frame
	check(owner.telemetry_fingerprint() == before_frames
		and int(owner.telemetry_snapshot()["last_tick"]) == 0,
		"render frames do not advance Vision or telemetry")

	check(owner.advance_authority_tick(1, generation), "tick 1 performs first evaluation")
	var visible := world.get_projection(101)
	var visible_record := _record_for(visible, 201)
	check(bool(visible.get("ok", false)) and int(visible.get("completed_tick", 0)) == 1,
		"first cadence tick publishes at exact authority tick 1")
	check(int(visible_record.get("state", -1)) == STATE_VISIBLE
		and int(visible_record.get("transition", -1)) == TRANSITION_BECAME_VISIBLE,
		"first query discloses a visible target")

	target_definition["position"] = _point(Vector2i(100_000_000, 0))
	target_definition["revision"] = 2
	check(_native_ok(world.update_target(target_definition, 1)),
		"fixture moves target out of range at exact next revision")
	check(owner.advance_authority_tick(2, generation)
		and owner.advance_authority_tick(3, generation),
		"ticks 2 and 3 are deterministic zero-work cadence skips")
	var still_tick_one := world.get_projection(101)
	check(int(still_tick_one.get("completed_tick", 0)) == 1
		and int(_record_for(still_tick_one, 201).get("state", -1)) == STATE_VISIBLE,
		"cadence skips retain the prior complete projection")

	check(owner.advance_authority_tick(4, generation), "tick 4 performs second evaluation")
	var remembered := world.get_projection(101)
	var remembered_record := _record_for(remembered, 201)
	check(int(remembered.get("completed_tick", 0)) == 4
		and int(remembered_record.get("state", -1)) == STATE_REMEMBERED
		and int(remembered_record.get("transition", -1)) == TRANSITION_BECAME_REMEMBERED,
		"hidden target becomes memory on the next configured cadence tick")
	check(int(remembered_record.get("last_seen_tick", 0)) == 1
		and (remembered_record.get("last_known_position", {}) as Dictionary)
			== {"x": 4_000_000, "y": 0},
		"memory keeps only the last confirmed tick and position")

	for tick in range(5, 182):
		check(owner.advance_authority_tick(tick, generation),
			"memory fixture advances authority tick %d" % tick)
	var equal_boundary := world.get_projection(101)
	var equal_record := _record_for(equal_boundary, 201)
	check(int(equal_boundary.get("completed_tick", 0)) == 181
		and int(equal_record.get("state", -1)) == STATE_REMEMBERED
		and int(equal_record.get("transition", -1)) == TRANSITION_REMAINED_REMEMBERED,
		"memory remains at current_tick - last_seen_tick == memory_ticks")
	check(181 - int(equal_record.get("last_seen_tick", 0)) == 180,
		"equal memory boundary uses exact RaidClock tick inputs")

	for tick in range(182, 185):
		check(owner.advance_authority_tick(tick, generation),
			"expiry fixture advances authority tick %d" % tick)
	var expired := world.get_projection(101)
	var expired_record := _record_for(expired, 201)
	check(int(expired.get("completed_tick", 0)) == 184
		and int(expired_record.get("state", -1)) == STATE_UNKNOWN
		and int(expired_record.get("transition", -1)) == TRANSITION_MEMORY_EXPIRED,
		"first cadence after a greater-than memory delta emits exact expiry")
	check(not bool(expired_record.get("has_last_known_position", true)),
		"memory-expiry tombstone removes position knowledge")

	for tick in range(185, 194):
		check(owner.advance_authority_tick(tick, generation),
			"post-expiry fixture advances authority tick %d" % tick)
	var absent := world.get_projection(101)
	check(int(absent.get("completed_tick", 0)) == 193
		and _record_for(absent, 201).is_empty(),
		"expired identity is absent from the following complete projection")
	var telemetry := owner.telemetry_snapshot()
	var history := telemetry["history"] as Array
	check(int(telemetry["ticks_received"]) == 193
		and int(telemetry["evaluation_ticks"]) == 65
		and int(telemetry["cadence_skips"]) == 128,
		"telemetry accounts exact 20 Hz evaluations and zero-work skips")
	check(history.size() == Config.TELEMETRY_HISTORY_LIMIT
		and int((history[0] as Dictionary)["tick"]) == 4
		and int((history[-1] as Dictionary)["tick"]) == 193,
		"telemetry history stays at 64 ordered evaluation records")
	check(telemetry.is_read_only() and history.is_read_only()
		and (history[0] as Dictionary).is_read_only(),
		"telemetry snapshot and nested history are recursively immutable")
	check(not owner.telemetry_fingerprint().is_empty(),
		"bounded cadence telemetry has a stable fingerprint")
	check(owner.teardown(generation), "cadence fixture tears down")
	owner.queue_free()


func _test_budget_defer_and_deterministic_telemetry() -> void:
	var first := _build_budget_fixture(6_104)
	var second := _build_budget_fixture(6_104)
	check(first != null and second != null, "two isolated budget fixtures configure")
	if first == null or second == null:
		return
	var first_generation := first.generation()
	var second_generation := second.generation()
	for tick in range(1, 5):
		check(first.advance_authority_tick(tick, first_generation),
			"first budget fixture advances tick %d" % tick)
		check(second.advance_authority_tick(tick, second_generation),
			"second budget fixture advances tick %d" % tick)

	var telemetry := first.telemetry_snapshot()
	var history := telemetry["history"] as Array
	var last := history[-1] as Dictionary
	check(int(last["budget"]) == Config.WORK_BUDGET_PER_EVALUATION,
		"telemetry exposes the sealed per-evaluation budget")
	check(int(last["requested"]) == 16_555 and int(last["consumed"]) == 0,
		"conservative scheduler estimate exceeds 16,384 while cheap work costs zero")
	check(int(last["completed"]) == 1 and int(last["deferred"]) == 1
		and bool(last["budget_exhausted"]),
		"whole expensive observer defers while later cheap observer completes")
	check(int(telemetry["budget_exhaustions"]) == 2
		and int(telemetry["deferred_observers"]) == 2
		and int(telemetry["completed_observers"]) == 2,
		"per-tick exhaustion, deferral, and completion totals are exact")
	check(int(telemetry["failed_evaluations"]) == 0,
		"budget deferral is successful bounded scheduling, not a failed tick")

	var first_world := first.authority_world(first_generation)
	var expensive_projection := first_world.get_projection(100)
	var cheap_projection := first_world.get_projection(200)
	check(not bool(expensive_projection.get("ok", true))
		and int(expensive_projection.get("code", 0)) == STATUS_NOT_FOUND,
		"deferred observer never publishes a partial first projection")
	check(bool(cheap_projection.get("ok", false))
		and int(cheap_projection.get("completed_tick", 0)) == 4
		and int(cheap_projection.get("work_units", -1)) == 0,
		"later zero-candidate observer publishes atomically at the current cadence tick")
	check(first.telemetry_fingerprint() == second.telemetry_fingerprint(),
		"same fixed inputs and tick sequence produce identical telemetry fingerprints")
	check(first.teardown(first_generation) and second.teardown(second_generation),
		"isolated budget worlds tear down independently")
	first.queue_free()
	second.queue_free()


func _test_raid_phase_driver() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "vision_world_001"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid_id, &"vision_profile", &"player")
	var raid := RaidAuthority.new()
	check(admission.is_usable() and raid.configure(raid_id, admission, 6_105),
		"phase fixture creates admitted RaidAuthority")
	var owner := VisionOwner.new()
	root.add_child(owner)
	check(owner.configure(6_105), "phase fixture Vision owner configures")
	var owner_generation := owner.generation()
	var world := owner.authority_world(owner_generation)
	check(_native_ok(world.register_observer(_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 301, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))) and _native_ok(world.register_target(_target_definition(
		Config.TARGET_PROFILE_PLAYER, 401, Vector2i(3_000_000, 0)
	))), "phase fixture native records are ready before activation")
	check(owner.register_with_raid_authority(raid),
		"Vision owner registers only in RaidAuthority VISION phase")
	check(not owner.register_with_raid_authority(raid)
		and owner.last_error == &"raid_authority_already_registered",
		"duplicate RaidAuthority driver registration is rejected")
	var raid_generation := raid.generation()
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid_generation),
		"phase fixture raid activates")
	check(raid.advance_one(raid_generation), "RaidAuthority drives Vision tick 1")
	check(int(world.get_projection(301).get("completed_tick", 0)) == 1,
		"phase-3 handler publishes first projection at RaidClock tick 1")
	check(not owner.advance_authority_tick(2, owner_generation)
		and owner.last_error == &"vision_tick_driver_is_raid_authority",
		"direct driving is sealed after RaidAuthority registration")
	check(raid.advance_one(raid_generation) and raid.advance_one(raid_generation),
		"RaidAuthority drives two exact zero-work cadence ticks")
	check(int(world.get_projection(301).get("completed_tick", 0)) == 1,
		"phase-driven cadence retains projection between evaluations")
	check(raid.advance_one(raid_generation), "RaidAuthority drives Vision tick 4")
	check(int(world.get_projection(301).get("completed_tick", 0)) == 4,
		"phase-driven projection refreshes exactly on tick 4")
	check(raid.last_phase_trace[RaidAuthority.TickPhase.VISION] == &"vision",
		"RaidAuthority phase trace places the owner in canonical phase 3")
	var before_frame := owner.telemetry_fingerprint()
	check(before_frame != "", "phase-driven telemetry fingerprint is available")
	check(raid.teardown(raid_generation),
		"RaidAuthority clears its phase callback before owner teardown")
	check(owner.teardown(owner_generation),
		"Vision owner tears down after its canonical driver")
	owner.queue_free()


func _build_budget_fixture(world_id: int) -> RaidVisionWorldOwner:
	var owner := VisionOwner.new()
	root.add_child(owner)
	if not owner.configure(world_id):
		check(false, "budget owner configures: " + String(owner.last_error))
		owner.queue_free()
		return null
	var generation := owner.generation()
	var world := owner.authority_world(generation)
	var segments: Array[Dictionary] = []
	for index in 128:
		var x := 30_000_000 + index * 1_000
		segments.append({
			"id": index + 1,
			"a": {"x": x, "y": -2_000_000},
			"b": {"x": x, "y": -1_000_000},
			"mask": Config.OCCLUDER_LAYER_STRUCTURE,
			"two_sided": true,
		})
	if not _native_ok(world.set_occluder_segments(segments, 1)):
		check(false, "budget fixture installs 128 bounded segments")
		owner.teardown(generation)
		owner.queue_free()
		return null
	if not _native_ok(world.register_observer(_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 100, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))):
		check(false, "budget fixture registers expensive urgent observer")
		owner.teardown(generation)
		owner.queue_free()
		return null
	if not _native_ok(world.register_observer(_observer_definition(
		Config.OBSERVER_PROFILE_MUTANT,
		200,
		Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0)
	))):
		check(false, "budget fixture registers cheap later observer")
		owner.teardown(generation)
		owner.queue_free()
		return null
	for index in 43:
		var position := Vector2i(
			1_000_000 + (index % 10) * 100_000,
			(index / 10) * 100_000,
		)
		if not _native_ok(world.register_target(_target_definition(
			Config.TARGET_PROFILE_PLAYER, 1_000 + index, position
		))):
			check(false, "budget fixture registers target %d" % index)
			owner.teardown(generation)
			owner.queue_free()
			return null
	return owner


func _observer_definition(
	profile_id: String,
	observer_id: int,
	position: Vector2i,
	facing: Vector2i,
	revision: int = 1
) -> Dictionary:
	var profile := Config.observer_profile(profile_id)
	return {
		"id": observer_id,
		"position": _point(position),
		"facing": _point(facing),
		"range": int(profile.get("range_raw", 0)),
		"cone_cos_million": int(profile.get("cone_cos_million", -1)),
		"full_circle": bool(profile.get("full_circle", false)),
		"target_mask": int(profile.get("target_mask", 0)),
		"occluder_mask": int(profile.get("occluder_mask", 0)),
		"memory_ticks": int(profile.get("memory_ticks", -1)),
		"priority": int(profile.get("priority", 0)),
		"urgent": bool(profile.get("urgent", false)),
		"revision": revision,
	}


func _target_definition(
	profile_id: String,
	target_id: int,
	position: Vector2i,
	revision: int = 1
) -> Dictionary:
	var profile := Config.target_profile(profile_id)
	return {
		"id": target_id,
		"position": _point(position),
		"mask": int(profile.get("mask", 0)),
		"sample_policy": int(profile.get("sample_policy", -1)),
		"sample_offsets": (profile.get("sample_offsets", []) as Array).duplicate(true),
		"revision": revision,
	}


func _point(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}


func _record_for(projection: Dictionary, target_id: int) -> Dictionary:
	for record_value in projection.get("records", []) as Array:
		var record := record_value as Dictionary
		if int(record.get("target_id", 0)) == target_id:
			return record
	return {}


func _native_ok(result: Dictionary) -> bool:
	return bool(result.get("ok", false))
