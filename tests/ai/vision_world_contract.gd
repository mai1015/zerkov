extends SceneTree
## Run with: Godot --headless --path . --audio-driver Dummy \
##   --script res://tests/ai/vision_world_contract.gd
##
## Production actor identity/liveness remains task 6.2. This contract uses the
## task-6.1 owner's sealed-profile ports to prove configuration, authority-phase
## authentication, cadence, memory inputs, bounded scheduling, failure
## quarantine, detached projections, and synchronous capability invalidation.

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

class ContractVisionOwner extends VisionOwner:
	func native_weak_for_contract() -> WeakRef:
		return weakref(_native_world)

	func force_native_query_for_contract(observer_id: int, tick: int) -> Dictionary:
		return _native_world.query_observer(observer_id, tick)


var checks: int = 0
var failures: int = 0
var forged_callback_results: Array[bool] = []


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
	_test_strict_numeric_types()
	_test_units_masks_ranges_cones_and_samples()
	await _test_owner_configuration_and_lifecycle()
	await _test_cadence_memory_and_render_independence()
	_test_budget_defer_and_deterministic_telemetry()
	_test_fixed_phase_slot_and_callback_authentication()
	_test_partial_native_failure_quarantine()
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
	var accepted_preflight := preflight.get("accepted_record", {}) as Dictionary
	check(accepted_preflight.is_read_only()
		and (accepted_preflight.get("locked_provenance", {}) as Dictionary).is_read_only(),
		"runtime fingerprint is accompanied by its immutable accepted record")
	check(String(preflight.get("fingerprint", ""))
		== ZCanonicalValue.sha256(accepted_preflight),
		"runtime fingerprint hashes the accepted record rather than an expected template")

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(Config.ADDON_LOCK_PATH))
	check(parsed is Dictionary, "project add-on lock parses")
	if not parsed is Dictionary:
		return
	var lock_document := parsed as Dictionary
	var locked := Config.validate_lock_document(lock_document, true)
	check(bool(locked.get("ok", false)), "exact installed lock and artifacts validate")
	var accepted_lock := locked.get("accepted_record", {}) as Dictionary
	check(accepted_lock.is_read_only()
		and (accepted_lock.get("source", {}) as Dictionary).is_read_only()
		and (accepted_lock.get("artifacts", []) as Array).is_read_only(),
		"validated lock provenance is recursively immutable")
	check(String(locked.get("fingerprint", "")) == ZCanonicalValue.sha256(accepted_lock),
		"lock fingerprint hashes the normalized accepted lock record")

	var duplicate_lock := lock_document.duplicate(true)
	var duplicate_addons := duplicate_lock["addons"] as Array
	duplicate_addons.append(_common_vision_entry(duplicate_lock).duplicate(true))
	var duplicate_result := Config.validate_lock_document(duplicate_lock)
	check(not bool(duplicate_result.get("ok", true))
		and duplicate_result.get("reason") == &"common_vision_lock_duplicate",
		"duplicate Common Vision provenance is rejected")

	var source_cases := [
		["git_head", "0".repeat(40)],
		["release_source_revision", "1".repeat(40)],
		["package_worktree_dirty", false],
		["package_file_count", Config.EXPECTED_PACKAGE_FILE_COUNT + 1],
		["package_tree_sha256", "2".repeat(64)],
		["release_manifest_sha256", "3".repeat(64)],
	]
	for source_case in source_cases:
		var altered := lock_document.duplicate(true)
		var source := _common_vision_entry(altered)["source"] as Dictionary
		source[source_case[0]] = source_case[1]
		var result := Config.validate_lock_document(altered)
		check(not bool(result.get("ok", true))
			and result.get("reason") == &"common_vision_lock_provenance_incompatible",
			"lock provenance mismatch is rejected for %s" % source_case[0])

	var artifact_cases := [
		["platform", "linux"],
		["arch", "x86_64"],
		["build", "release"],
		["status", "built"],
		["release_manifest_matches", true],
		["release_manifest_sha256", "4".repeat(64)],
	]
	for artifact_case in artifact_cases:
		var altered := lock_document.duplicate(true)
		var artifact := (_common_vision_entry(altered)["native_artifacts"] as Array)[0] \
			as Dictionary
		artifact[artifact_case[0]] = artifact_case[1]
		var result := Config.validate_lock_document(altered)
		check(not bool(result.get("ok", true))
			and result.get("reason") == &"common_vision_lock_artifact_incompatible",
			"artifact provenance mismatch is rejected for %s" % artifact_case[0])

	var tampered := configuration.duplicate(true)
	(tampered["observer_profiles"] as Array)[0]["memory_ticks"] = 181
	var tampered_result := Config.validate_configuration(tampered, true)
	check(not bool(tampered_result.get("ok", true))
		and tampered_result.get("reason") == &"configuration_fingerprint_mismatch",
		"semantically valid but unsealed configuration is rejected")

	var bad_provenance := configuration.duplicate(true)
	var bad_source := (bad_provenance["provenance"] as Dictionary)["source"] as Dictionary
	bad_source["git_head"] = "5".repeat(40)
	var bad_provenance_result := Config.validate_configuration(bad_provenance, false)
	check(not bool(bad_provenance_result.get("ok", true))
		and bad_provenance_result.get("reason")
			== &"configuration_provenance_incompatible",
		"configuration with relabeled lock provenance is rejected")

	var duplicate_profile := configuration.duplicate(true)
	var observer_profiles := duplicate_profile["observer_profiles"] as Array
	observer_profiles.append((observer_profiles[0] as Dictionary).duplicate(true))
	var duplicate_profile_result := Config.validate_configuration(duplicate_profile, false)
	check(not bool(duplicate_profile_result.get("ok", true))
		and duplicate_profile_result.get("reason") == &"observer_profile_duplicate",
		"duplicate observer configuration is rejected")


func _test_strict_numeric_types() -> void:
	var schema_string := Config.configuration()
	schema_string["schema_version"] = str(Config.CONFIG_SCHEMA_VERSION)
	check(Config.validate_configuration(schema_string, false).get("reason")
		== &"configuration_identity_incompatible",
		"configuration schema numeric strings are rejected before conversion")

	for key in [
		"role", "spatial_cell_size_raw", "max_visited_cells",
		"canonical_coordinate_limit_raw",
	]:
		var malformed := Config.configuration()
		var world := malformed["world"] as Dictionary
		world[key] = str(world[key])
		check(Config.validate_configuration(malformed, false).get("reason")
			== &"world_configuration_invalid",
			"world numeric string is rejected for %s" % key)

	for key in [
		"authority_tick_rate", "first_evaluation_tick", "cadence_interval_ticks",
		"work_budget_per_evaluation", "telemetry_history_limit",
		"telemetry_counter_limit",
	]:
		var malformed := Config.configuration()
		var schedule := malformed["schedule"] as Dictionary
		schedule[key] = str(schedule[key])
		check(Config.validate_configuration(malformed, false).get("reason")
			== &"vision_schedule_invalid",
			"schedule numeric string is rejected for %s" % key)

	for key in [
		"target_player", "target_scav", "target_mutant",
		"occluder_structure", "occluder_vegetation",
	]:
		var malformed := Config.configuration()
		var layers := malformed["layers"] as Dictionary
		layers[key] = str(layers[key])
		check(Config.validate_configuration(malformed, false).get("reason")
			== &"vision_layers_invalid",
			"layer numeric string is rejected for %s" % key)

	for key in [
		"range_raw", "cone_cos_million", "target_mask", "occluder_mask",
		"memory_ticks", "priority",
	]:
		var malformed := Config.configuration()
		var observer := (malformed["observer_profiles"] as Array)[0] as Dictionary
		observer[key] = str(observer[key])
		check(Config.validate_configuration(malformed, false).get("reason")
			== &"observer_profile_invalid",
			"observer numeric string is rejected for %s" % key)

	for key in ["mask", "sample_policy"]:
		var malformed := Config.configuration()
		var target := (malformed["target_profiles"] as Array)[0] as Dictionary
		target[key] = str(target[key])
		check(Config.validate_configuration(malformed, false).get("reason")
			== &"target_profile_invalid",
			"target numeric string is rejected for %s" % key)

	var sample_string := Config.configuration()
	var sample := (((sample_string["target_profiles"] as Array)[0] as Dictionary)[
		"sample_offsets"
	] as Array)[0] as Dictionary
	sample["x"] = "0"
	check(Config.validate_configuration(sample_string, false).get("reason")
		== &"target_sample_invalid", "sample numeric strings are rejected")

	var runtime_string := Config.configuration()
	(runtime_string["runtime_contract"] as Dictionary)["protocol_version"] = "1"
	check(Config.validate_configuration(runtime_string, false).get("reason")
		== &"configuration_runtime_contract_incompatible",
		"runtime-contract numeric strings are rejected")

	var parsed := JSON.parse_string(FileAccess.get_file_as_string(Config.ADDON_LOCK_PATH)) \
		as Dictionary
	var lock_schema_string := parsed.duplicate(true)
	lock_schema_string["schema_version"] = "1"
	check(Config.validate_lock_document(lock_schema_string).get("reason")
		== &"addon_lock_schema_incompatible", "lock schema numeric strings are rejected")
	var lock_count_string := parsed.duplicate(true)
	(_common_vision_entry(lock_count_string)["source"] as Dictionary)[
		"package_file_count"
	] = str(Config.EXPECTED_PACKAGE_FILE_COUNT)
	check(Config.validate_lock_document(lock_count_string).get("reason")
		== &"common_vision_lock_provenance_incompatible",
		"lock provenance numeric strings are rejected")
	var lock_bool_string := parsed.duplicate(true)
	((_common_vision_entry(lock_bool_string)["native_artifacts"] as Array)[0] \
		as Dictionary)["release_manifest_matches"] = "false"
	check(Config.validate_lock_document(lock_bool_string).get("reason")
		== &"common_vision_lock_artifacts_invalid",
		"artifact boolean strings are rejected")


func _test_units_masks_ranges_cones_and_samples() -> void:
	check(WorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT == Config.EXPECTED_COORDINATE_SCALE,
		"ZWorldUnits is the sole Common Vision coordinate scale")
	var one_tile := WorldUnits.godot_to_vision(Vector2(32.0, -32.0))
	check(one_tile.ok and one_tile.vector2i_value == Vector2i(1_000_000, -1_000_000),
		"one 32 px source tile converts to one Vision world unit")
	var restored_tile := WorldUnits.vision_to_godot(one_tile.vector2i_value)
	check(restored_tile.ok and restored_tile.vector2_value == Vector2(32.0, -32.0),
		"Vision tile coordinates round-trip through ZWorldUnits")

	var positive_boundary := WorldUnits.godot_to_canonical(Vector2(
		WorldUnits.MAX_GODOT_COORDINATE_PX, -WorldUnits.MAX_GODOT_COORDINATE_PX
	))
	check(positive_boundary.ok and positive_boundary.vector2i_value
		== Vector2i(WorldUnits.MAX_CANONICAL_RAW, -WorldUnits.MAX_CANONICAL_RAW),
		"exact positive and negative Godot safety boundaries convert without wrap")
	var restored_boundary := WorldUnits.canonical_to_godot(
		Vector2i(WorldUnits.MAX_CANONICAL_RAW, -WorldUnits.MAX_CANONICAL_RAW)
	)
	check(restored_boundary.ok and restored_boundary.vector2_value == Vector2(
		WorldUnits.MAX_GODOT_COORDINATE_PX, -WorldUnits.MAX_GODOT_COORDINATE_PX
	), "exact canonical safety boundaries round-trip")
	var positive_outside := WorldUnits.godot_to_canonical(Vector2(
		WorldUnits.MAX_GODOT_COORDINATE_PX + 1.0, 17.0
	))
	var negative_outside := WorldUnits.godot_to_canonical(Vector2(
		-WorldUnits.MAX_GODOT_COORDINATE_PX - 1.0, -17.0
	))
	check(not positive_outside.ok and positive_outside.vector2i_value == Vector2i.ZERO
		and not negative_outside.ok and negative_outside.vector2i_value == Vector2i.ZERO,
		"one-pixel-outside inputs reject atomically with no wrapped partial point")
	check(not WorldUnits.canonical_to_godot(Vector2i(
		WorldUnits.MAX_CANONICAL_RAW + 1, 0
	)).ok and not WorldUnits.canonical_to_godot(Vector2i(
		-WorldUnits.MAX_CANONICAL_RAW - 1, 0
	)).ok, "one-raw-unit-outside canonical inputs reject on both signs")

	var sample_raw := Vector2i(0, Config.MAX_SAMPLE_OFFSET_RAW)
	var sample_px := WorldUnits.vision_to_godot(sample_raw)
	check(sample_px.ok and sample_px.vector2_value == Vector2(0.0, 8.0),
		"quarter-tile target sample converts to exactly eight Godot pixels")
	check(WorldUnits.godot_to_vision(sample_px.vector2_value).vector2i_value == sample_raw,
		"target sample offset round-trips without a second quantizer")
	var maximum_range_px := WorldUnits.vision_to_godot(
		Vector2i(Config.MAX_PROFILE_RANGE_RAW, 0)
	)
	check(maximum_range_px.ok and maximum_range_px.vector2_value.x == 576.0,
		"sealed 18-tile maximum sight range is 576 Godot pixels")
	check(int((Config.configuration()["world"] as Dictionary)[
		"canonical_coordinate_limit_raw"
	]) == WorldUnits.MAX_CANONICAL_RAW,
		"sealed Vision world records the checked Vector2i coordinate domain")

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
	(valid_boundary["observer_profiles"] as Array)[0]["memory_ticks"] \
		= Config.MAX_MEMORY_TICKS
	check(bool(Config.validate_configuration(valid_boundary, false).get("ok", false)),
		"documented zero cone cosine and game memory maximum are valid bounds")
	var invalid_cases := [
		["range_raw", 0, &"observer_range_invalid"],
		["range_raw", Config.MAX_PROFILE_RANGE_RAW + 1, &"observer_range_invalid"],
		["cone_cos_million", Config.CONE_COS_SCALE + 1, &"observer_cone_invalid"],
		["memory_ticks", Config.MAX_MEMORY_TICKS + 1, &"observer_memory_invalid"],
	]
	for invalid_case in invalid_cases:
		var invalid := Config.configuration()
		(invalid["observer_profiles"] as Array)[0][invalid_case[0]] = invalid_case[1]
		check(Config.validate_configuration(invalid, false).get("reason") == invalid_case[2],
			"observer bound rejects %s=%s" % [invalid_case[0], invalid_case[1]])
	var bad_mask := Config.configuration()
	(bad_mask["target_profiles"] as Array)[0]["mask"] = 0
	check(Config.validate_configuration(bad_mask, false).get("reason")
		== &"target_mask_invalid", "zero target mask is rejected")
	var too_many_samples := Config.configuration()
	var too_many_offsets := ((too_many_samples["target_profiles"] as Array)[0] \
		as Dictionary)["sample_offsets"] as Array
	too_many_offsets.append({"x": 250_000, "y": 0})
	check(Config.validate_configuration(too_many_samples, false).get("reason")
		== &"target_sample_count_invalid", "a fourth production target sample is rejected")
	var bad_sample := Config.configuration()
	var bad_offsets := ((bad_sample["target_profiles"] as Array)[0] as Dictionary)[
		"sample_offsets"
	] as Array
	(bad_offsets[1] as Dictionary)["y"] = Config.MAX_SAMPLE_OFFSET_RAW + 1
	check(Config.validate_configuration(bad_sample, false).get("reason")
		== &"target_sample_out_of_range",
		"sample outside the quarter-tile bound is rejected")
	var bad_cadence := Config.configuration()
	(bad_cadence["schedule"] as Dictionary)["cadence_interval_ticks"] = 7
	check(Config.validate_configuration(bad_cadence, false).get("reason")
		== &"vision_cadence_invalid",
		"cadence that does not divide the 60 Hz authority clock is rejected")
	var bad_budget := Config.configuration()
	(bad_budget["schedule"] as Dictionary)["work_budget_per_evaluation"] \
		= Config.NATIVE_MAX_WORK_UNITS + 1
	check(Config.validate_configuration(bad_budget, false).get("reason")
		== &"vision_work_budget_invalid", "budget above the native cap is rejected")
	var bad_visit_limit := Config.configuration()
	(bad_visit_limit["world"] as Dictionary)["max_visited_cells"] \
		= Config.NATIVE_MAX_VISITED_CELLS + 1
	check(Config.validate_configuration(bad_visit_limit, false).get("reason")
		== &"max_visited_cells_invalid", "visited-cell budget above native cap is rejected")


func _test_owner_configuration_and_lifecycle() -> void:
	var invalid_owner := ContractVisionOwner.new()
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

	var fixture := _new_bound_fixture(6_101, "owner_lifecycle", invalid_owner)
	if fixture.is_empty():
		invalid_owner.queue_free()
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as ContractVisionOwner
	var generation := owner.generation()
	var native_weak := owner.native_weak_for_contract()
	check(not owner.has_method("authority_world")
		and not owner.has_method("advance_authority_tick")
		and not owner.has_method("handle_raid_phase")
		and owner.get_child_count() == 0,
		"owner exposes no mutable native handle or public direct tick callback")
	var receipt := owner.configuration_receipt()
	check(receipt.is_read_only() and bool(receipt.get("active", false))
		and not bool(receipt.get("native_handle_exposed", true))
		and receipt.get("phase_handler_id") == String(VisionOwner.PHASE_HANDLER_ID)
		and receipt.get("configuration_fingerprint") == Config.SEALED_FINGERPRINT,
		"immutable receipt records the fixed slot and absence of a native handle")
	check(not owner.configure(6_102)
		and owner.last_error == &"owner_already_configured",
		"duplicate owner configuration is rejected without replacing state")
	check(owner.world_id() == 6_101 and owner.generation() == generation,
		"duplicate configuration cannot reset accepted state")

	var other_raid := RaidAuthority.new()
	check(not owner.register_target(
		other_raid, 201, Config.TARGET_PROFILE_PLAYER, Vector2i.ZERO, 1, generation
	) and owner.last_error == &"raid_authority_binding_invalid",
		"world mutation requires the exact bound RaidAuthority")
	check(not owner.register_target(
		raid, 201, Config.TARGET_PROFILE_PLAYER, Vector2i.ZERO, 1, generation + 1
	) and owner.last_error == &"stale_generation",
		"world mutation requires the exact owner generation")
	check(owner.register_observer(
		raid, 101, Config.OBSERVER_PROFILE_SCAV, Vector2i.ZERO,
		Vector2i(1_000_000, 0), 1, generation
	), "sealed-profile observer port accepts a bounded fixture")
	check(owner.register_target(
		raid, 201, Config.TARGET_PROFILE_PLAYER, Vector2i(4_000_000, 0), 1, generation
	), "sealed-profile target port accepts a bounded fixture")
	check(not owner.register_target(
		raid, 202, Config.TARGET_PROFILE_PLAYER,
		Vector2i(0, WorldUnits.MAX_CANONICAL_RAW), 1, generation
	) and owner.last_error == &"vision_target_definition_invalid",
		"target base plus sealed samples is rejected before it can exceed the game domain")
	check(owner.register_target(
		raid, 202, Config.TARGET_PROFILE_PLAYER,
		Vector2i(0, WorldUnits.MAX_CANONICAL_RAW - Config.MAX_SAMPLE_OFFSET_RAW),
		1, generation
	), "exact safe target-plus-sample boundary remains accepted after rejection")
	var before := owner.observer_projection(raid, 101, generation)
	check(before.is_read_only() and not bool(before.get("ok", true))
		and int(before.get("code", 0)) == STATUS_NOT_FOUND,
		"projection port returns only a detached immutable native value copy")

	var forged: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 1,
		_empty_raid_intents()
	)
	check(typeof(forged) == TYPE_BOOL and not bool(forged)
		and owner.last_error == &"vision_phase_attestation_failed"
		and int(owner.telemetry_snapshot()["ticks_received"]) == 0,
		"direct callback invocation before authority dispatch is inert")

	var retained_projection := before
	var retained_mutation := Callable(owner, "register_target").bind(
		raid, 202, Config.TARGET_PROFILE_PLAYER, Vector2i.ZERO, 1, generation
	)
	check(not owner.teardown(generation + 1)
		and owner.last_error == &"stale_generation",
		"stale generation cannot tear down Vision")
	check(owner.teardown(generation), "exact generation tears down Vision")
	check(owner.lifecycle == VisionOwner.Lifecycle.TORN_DOWN
		and owner.generation() == generation + 1
		and native_weak.get_ref() == null,
		"teardown synchronously frees native state and invalidates the generation")
	check(not bool(retained_mutation.call()) and owner.last_error == &"stale_generation",
		"a retained mutation callable is inert after synchronous teardown")
	check(retained_projection.is_read_only()
		and int(retained_projection.get("code", 0)) == STATUS_NOT_FOUND,
		"a retained projection is an immutable detached value, not a capability")
	check(not owner.teardown(generation), "teardown cannot replay")
	owner.queue_free()
	check(raid.teardown(raid.generation()), "unused bound raid tears down")
	await process_frame

	var tree_owner := ContractVisionOwner.new()
	var tree_fixture := _new_bound_fixture(6_102, "tree_lifecycle", tree_owner)
	if not tree_fixture.is_empty():
		var tree_raid := tree_fixture["raid"] as RaidAuthority
		var tree_native_weak := tree_owner.native_weak_for_contract()
		tree_owner.queue_free()
		await process_frame
		check(tree_native_weak.get_ref() == null,
			"scene-tree exit synchronously releases privately retained native state")
		check(tree_raid.teardown(tree_raid.generation()), "tree fixture raid tears down")


func _test_cadence_memory_and_render_independence() -> void:
	var fixture := _new_bound_fixture(6_103, "cadence_memory")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var raid := fixture["raid"] as RaidAuthority
	var generation := owner.generation()
	check(owner.register_observer(
		raid, 101, Config.OBSERVER_PROFILE_SCAV, Vector2i.ZERO,
		Vector2i(1_000_000, 0), 1, generation
	), "cadence observer registers through the game-owned sealed-profile port")
	check(owner.register_target(
		raid, 201, Config.TARGET_PROFILE_PLAYER, Vector2i(4_000_000, 0), 1, generation
	), "cadence target registers through the game-owned sealed-profile port")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"cadence RaidAuthority activates")

	var before_frames := owner.telemetry_fingerprint()
	await process_frame
	await process_frame
	check(owner.telemetry_fingerprint() == before_frames
		and int(owner.telemetry_snapshot()["last_attempted_tick"]) == 0,
		"render frames do not advance Vision or telemetry")

	check(raid.advance_one(raid.generation()), "authority tick 1 performs first evaluation")
	var visible := owner.observer_projection(raid, 101, generation)
	var visible_record := _record_for(visible, 201)
	check(visible.is_read_only() and (visible.get("records", []) as Array).is_read_only(),
		"published projection and nested records are recursively immutable")
	check(bool(visible.get("ok", false)) and int(visible.get("completed_tick", 0)) == 1,
		"first cadence tick publishes at exact authority tick 1")
	check(int(visible_record.get("state", -1)) == STATE_VISIBLE
		and int(visible_record.get("transition", -1)) == TRANSITION_BECAME_VISIBLE,
		"first projection discloses a visible target")

	check(owner.update_target(
		raid, 201, Config.TARGET_PROFILE_PLAYER, Vector2i(100_000_000, 0),
		2, 1, generation
	), "target moves out of range at the exact next revision")
	check(raid.advance_one(raid.generation()) and raid.advance_one(raid.generation()),
		"ticks 2 and 3 are deterministic zero-work cadence skips")
	var still_tick_one := owner.observer_projection(raid, 101, generation)
	check(int(still_tick_one.get("completed_tick", 0)) == 1
		and int(_record_for(still_tick_one, 201).get("state", -1)) == STATE_VISIBLE,
		"cadence skips retain the prior complete projection")

	check(raid.advance_one(raid.generation()), "tick 4 performs second evaluation")
	var remembered := owner.observer_projection(raid, 101, generation)
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
		check(raid.advance_one(raid.generation()),
			"memory fixture advances authority tick %d" % tick)
	var equal_boundary := owner.observer_projection(raid, 101, generation)
	var equal_record := _record_for(equal_boundary, 201)
	check(int(equal_boundary.get("completed_tick", 0)) == 181
		and int(equal_record.get("state", -1)) == STATE_REMEMBERED
		and int(equal_record.get("transition", -1)) == TRANSITION_REMAINED_REMEMBERED,
		"memory remains at current_tick - last_seen_tick == memory_ticks")
	check(181 - int(equal_record.get("last_seen_tick", 0)) == 180,
		"equal memory boundary uses exact RaidClock tick inputs")

	for tick in range(182, 185):
		check(raid.advance_one(raid.generation()),
			"expiry fixture advances authority tick %d" % tick)
	var expired := owner.observer_projection(raid, 101, generation)
	var expired_record := _record_for(expired, 201)
	check(int(expired.get("completed_tick", 0)) == 184
		and int(expired_record.get("state", -1)) == STATE_UNKNOWN
		and int(expired_record.get("transition", -1)) == TRANSITION_MEMORY_EXPIRED,
		"first cadence after a greater-than memory delta emits exact expiry")
	check(not bool(expired_record.get("has_last_known_position", true)),
		"memory-expiry tombstone removes position knowledge")

	for tick in range(185, 194):
		check(raid.advance_one(raid.generation()),
			"post-expiry fixture advances authority tick %d" % tick)
	var absent := owner.observer_projection(raid, 101, generation)
	check(int(absent.get("completed_tick", 0)) == 193
		and _record_for(absent, 201).is_empty(),
		"expired identity is absent from the following complete projection")
	var telemetry := owner.telemetry_snapshot()
	var history := telemetry["history"] as Array
	check(int(telemetry["ticks_received"]) == 193
		and int(telemetry["evaluation_attempts"]) == 65
		and int(telemetry["evaluation_ticks"]) == 65
		and int(telemetry["cadence_skips"]) == 128,
		"telemetry accounts exact 20 Hz attempts, completions, and zero-work skips")
	check(history.size() == Config.TELEMETRY_HISTORY_LIMIT
		and int((history[0] as Dictionary)["tick"]) == 4
		and int((history[-1] as Dictionary)["tick"]) == 193,
		"telemetry history stays at 64 ordered evaluation records")
	check(telemetry.is_read_only() and history.is_read_only()
		and (history[0] as Dictionary).is_read_only(),
		"telemetry snapshot and nested history are recursively immutable")
	check(not owner.telemetry_fingerprint().is_empty(),
		"bounded cadence telemetry has a stable fingerprint")
	_cleanup_fixture(fixture)


func _test_budget_defer_and_deterministic_telemetry() -> void:
	var first := _build_budget_fixture(6_104, "budget_first")
	var second := _build_budget_fixture(6_104, "budget_second")
	check(not first.is_empty() and not second.is_empty(),
		"two isolated budget fixtures configure")
	if first.is_empty() or second.is_empty():
		return
	for _tick in range(1, 5):
		check((first["raid"] as RaidAuthority).advance_one(
			(first["raid"] as RaidAuthority).generation()
		), "first budget fixture advances one exact authority tick")
		check((second["raid"] as RaidAuthority).advance_one(
			(second["raid"] as RaidAuthority).generation()
		), "second budget fixture advances one exact authority tick")

	var first_owner := first["owner"] as RaidVisionWorldOwner
	var first_raid := first["raid"] as RaidAuthority
	var generation := first_owner.generation()
	var telemetry := first_owner.telemetry_snapshot()
	var history := telemetry["history"] as Array
	var last := history[-1] as Dictionary
	check(int(last["budget"]) == Config.WORK_BUDGET_PER_EVALUATION,
		"telemetry exposes the sealed per-evaluation budget")
	check(int(last["requested"]) == 16_555 and int(last["consumed"]) == 0,
		"conservative scheduler estimate exceeds 16,384 while cheap work costs zero")
	check(int(last["completed"]) == 1 and int(last["deferred"]) == 1
		and bool(last["budget_exhausted"]) and bool(last["ok"]),
		"whole expensive observer defers while later cheap observer completes")
	check(int(telemetry["budget_exhaustions"]) == 2
		and int(telemetry["deferred_observers"]) == 2
		and int(telemetry["completed_observers"]) == 2,
		"per-tick exhaustion, deferral, and completion totals are exact")
	check(int(telemetry["failed_evaluations"]) == 0,
		"budget deferral is successful bounded scheduling, not a failed tick")

	var expensive_projection := first_owner.observer_projection(first_raid, 100, generation)
	var cheap_projection := first_owner.observer_projection(first_raid, 200, generation)
	check(not bool(expensive_projection.get("ok", true))
		and int(expensive_projection.get("code", 0)) == STATUS_NOT_FOUND,
		"deferred observer never publishes a partial first projection")
	check(bool(cheap_projection.get("ok", false))
		and int(cheap_projection.get("completed_tick", 0)) == 4
		and int(cheap_projection.get("work_units", -1)) == 0,
		"later zero-candidate observer publishes atomically at the cadence tick")
	check(first_owner.telemetry_fingerprint()
		== (second["owner"] as RaidVisionWorldOwner).telemetry_fingerprint(),
		"same fixed inputs and tick sequence produce identical telemetry fingerprints")
	_cleanup_fixture(first)
	_cleanup_fixture(second)


func _test_fixed_phase_slot_and_callback_authentication() -> void:
	forged_callback_results.clear()
	var fixture := _new_bound_fixture(6_106, "fixed_slot")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var generation := owner.generation()
	var second_owner := VisionOwner.new()
	root.add_child(second_owner)
	check(second_owner.configure(6_107), "second Vision owner configures independently")
	check(not second_owner.register_with_raid_authority(raid)
		and second_owner.last_error == &"handler_id_duplicate",
		"one fixed Vision handler slot rejects a second owner on the raid")
	check(_method_argument_count(owner, &"register_with_raid_authority") == 1,
		"Vision owner registration has no caller-selected handler identity")

	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		&"aaa_forged_vision",
		Callable(self, "_forged_vision_handler").bind(owner),
		raid.generation(),
	), "adversarial earlier Vision handler registers for callback forgery test")
	check(owner.register_observer(
		raid, 301, Config.OBSERVER_PROFILE_SCAV, Vector2i.ZERO,
		Vector2i(1_000_000, 0), 1, generation
	) and owner.register_target(
		raid, 401, Config.TARGET_PROFILE_PLAYER, Vector2i(3_000_000, 0), 1, generation
	), "fixed-slot fixture records are ready before activation")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"fixed-slot RaidAuthority activates")
	check(not raid.is_dispatching_phase_handler(
		RaidAuthority.TickPhase.VISION, 1, VisionOwner.PHASE_HANDLER_ID, raid.generation()
	), "authority phase attestation is false outside synchronous dispatch")
	var direct: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 1,
		_empty_raid_intents()
	)
	check(typeof(direct) == TYPE_BOOL and not bool(direct)
		and int(owner.telemetry_snapshot()["ticks_received"]) == 0,
		"direct callback cannot advance an otherwise active bound owner")
	var direct_advance: Variant = owner.call(
		"_advance_attested_tick", raid, RaidAuthority.TickPhase.VISION, 1
	)
	check(typeof(direct_advance) == TYPE_BOOL and not bool(direct_advance)
		and int(owner.telemetry_snapshot()["ticks_received"]) == 0,
		"direct internal tick invocation cannot forge phase attestation")

	check(raid.advance_one(raid.generation()),
		"RaidAuthority drives the fixed Vision slot at tick 1")
	check(forged_callback_results == [false],
		"a different handler in the same phase cannot forge the Vision slot")
	check(int(owner.telemetry_snapshot()["ticks_received"]) == 1
		and int(owner.observer_projection(raid, 301, generation).get("completed_tick", 0)) == 1,
		"only the authentic fixed callback advances and publishes tick 1")
	var replay: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 1,
		_empty_raid_intents()
	)
	check(typeof(replay) == TYPE_BOOL and not bool(replay)
		and owner.last_error == &"vision_phase_attestation_failed"
		and int(owner.telemetry_snapshot()["ticks_received"]) == 1,
		"replayed callback after dispatch is inert and leaves telemetry unchanged")
	check(raid.last_phase_trace[RaidAuthority.TickPhase.VISION] == &"vision",
		"authenticated callback remains in canonical RaidAuthority phase 3")

	var retained_callback := Callable(owner, "_handle_raid_phase").bind(
		raid, RaidAuthority.TickPhase.VISION, 2, _empty_raid_intents()
	)
	check(raid.teardown(raid.generation()), "fixed-slot raid tears down first")
	check(not bool(retained_callback.call()),
		"retained callback capability is inert after authority teardown")
	check(owner.teardown(generation), "fixed-slot owner tears down")
	check(second_owner.teardown(second_owner.generation()),
		"rejected second owner tears down without a binding")
	owner.queue_free()
	second_owner.queue_free()


func _test_partial_native_failure_quarantine() -> void:
	var native_world := CommonVisionWorld2D.new()
	check(_native_ok(native_world.configure(
		60_100, Config.OFFLINE_AUTHORITY_ROLE, Config.SPATIAL_CELL_SIZE_RAW,
		Config.MAX_VISITED_CELLS
	)), "native partial-failure control world configures")
	check(_native_ok(native_world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 1, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))) and _native_ok(native_world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_MUTANT, 2, Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0)
	))), "native partial-failure control observers register")
	check(_native_ok(native_world.query_observer(2, 4)),
		"later native observer is deliberately advanced to tick 4")
	var native_failure := native_world.advance(1, Config.WORK_BUDGET_PER_EVALUATION)
	check(not bool(native_failure.get("ok", true))
		and int(native_failure.get("completed", 0)) == 1
		and int(native_world.get_projection(1).get("completed_tick", 0)) == 1,
		"documented native failure reproduces publication by observer 1 before observer 2")
	check(_native_failure_metrics_are_present(native_failure),
		"native failure returns the exact accumulated metric prefix")
	native_world.free()

	var owner := ContractVisionOwner.new()
	var fixture := _new_bound_fixture(6_108, "partial_failure", owner)
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var generation := owner.generation()
	check(owner.register_observer(
		raid, 1, Config.OBSERVER_PROFILE_SCAV, Vector2i.ZERO,
		Vector2i(1_000_000, 0), 1, generation
	) and owner.register_observer(
		raid, 2, Config.OBSERVER_PROFILE_MUTANT, Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0), 1, generation
	), "owner partial-failure observers register")
	var forced_query := owner.force_native_query_for_contract(2, 4)
	check(_native_ok(forced_query),
		"test-only privileged seam prepares the documented tick-regression failure")
	var native_weak := owner.native_weak_for_contract()
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"partial-failure raid activates")
	check(not raid.advance_one(raid.generation())
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED,
		"native partial failure terminalizes the driving RaidAuthority")
	var telemetry := owner.telemetry_snapshot()
	var history := telemetry["history"] as Array
	var failure_record := history[-1] as Dictionary
	var status := telemetry["last_native_status"] as Dictionary
	print(
		"VISION_PARTIAL_FAILURE_METRICS requested=", status.get("requested", -1),
		" consumed=", status.get("consumed", -1),
		" completed=", status.get("completed", -1),
		" deferred=", status.get("deferred", -1),
		" invalidated=", status.get("invalidated", -1),
		" code=", status.get("code", -1),
		" diagnostic=", status.get("diagnostic", -1),
		" detail=", status.get("detail", -1),
	)
	check(owner.lifecycle == VisionOwner.Lifecycle.QUARANTINED
		and not owner.is_current_generation(generation)
		and native_weak.get_ref() == null,
		"owner quarantines and synchronously destroys partial native state")
	check(int(telemetry["last_attempted_tick"]) == 1
		and int(telemetry["last_successful_tick"]) == 0
		and int(telemetry["last_attempted_evaluation_tick"]) == 1
		and int(telemetry["last_evaluation_tick"]) == 0
		and int(telemetry["ticks_received"]) == 1
		and int(telemetry["evaluation_attempts"]) == 1
		and int(telemetry["evaluation_ticks"]) == 0
		and int(telemetry["failed_evaluations"]) == 1,
		"failed evaluation records attempted versus successful tick state exactly")
	check(not bool(failure_record["ok"]) and bool(failure_record["terminal"])
		and int(failure_record["tick"]) == 1
		and int(failure_record["requested"]) == int(status["requested"])
		and int(failure_record["consumed"]) == int(status["consumed"])
		and int(failure_record["completed"]) == int(status["completed"])
		and int(failure_record["deferred"]) == int(status["deferred"])
		and int(failure_record["invalidated"]) == int(status["invalidated"]),
		"terminal history preserves every exact native partial-failure metric")
	check(int(telemetry["requested_work_units"]) == int(status["requested"])
		and int(telemetry["consumed_work_units"]) == int(status["consumed"])
		and int(telemetry["completed_observers"]) == int(status["completed"])
		and int(telemetry["deferred_observers"]) == int(status["deferred"]),
		"bounded cumulative totals include the failed call's exact metric prefix")
	check(telemetry.is_read_only() and history.is_read_only()
		and failure_record.is_read_only() and status.is_read_only(),
		"partial-failure telemetry and nested metrics are immutable")
	check(not owner.register_target(
		raid, 9, Config.TARGET_PROFILE_PLAYER, Vector2i.ZERO, 1, generation
	) and owner.last_error == &"vision_owner_quarantined",
		"quarantine prevents every further native mutation")
	var replay: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 2,
		_empty_raid_intents()
	)
	check(typeof(replay) == TYPE_BOOL and not bool(replay)
		and int(owner.telemetry_snapshot()["ticks_received"]) == 1,
		"quarantined owner cannot advance again")
	check(owner.teardown(generation),
		"quarantined owner permits only explicit teardown before replacement")
	check(raid.teardown(raid.generation()), "failed partial-failure raid tears down")
	owner.queue_free()


func _build_budget_fixture(world_id: int, suffix: String) -> Dictionary:
	var fixture := _new_bound_fixture(world_id, suffix)
	if fixture.is_empty():
		return {}
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var raid := fixture["raid"] as RaidAuthority
	var generation := owner.generation()
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
	if not owner.set_occluder_segments(raid, segments, 1, generation):
		check(false, "budget fixture installs 128 bounded segments")
		_cleanup_fixture(fixture)
		return {}
	if not owner.register_observer(
		raid, 100, Config.OBSERVER_PROFILE_SCAV, Vector2i.ZERO,
		Vector2i(1_000_000, 0), 1, generation
	):
		check(false, "budget fixture registers expensive urgent observer")
		_cleanup_fixture(fixture)
		return {}
	if not owner.register_observer(
		raid, 200, Config.OBSERVER_PROFILE_MUTANT, Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0), 1, generation
	):
		check(false, "budget fixture registers cheap later observer")
		_cleanup_fixture(fixture)
		return {}
	for index in 43:
		var position := Vector2i(
			1_000_000 + (index % 10) * 100_000,
			(index / 10) * 100_000,
		)
		if not owner.register_target(
			raid, 1_000 + index, Config.TARGET_PROFILE_PLAYER, position, 1, generation
		):
			check(false, "budget fixture registers target %d" % index)
			_cleanup_fixture(fixture)
			return {}
	if not raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()):
		check(false, "budget fixture activates RaidAuthority")
		_cleanup_fixture(fixture)
		return {}
	return fixture


func _new_bound_fixture(
	world_id: int,
	suffix: String,
	provided_owner: RaidVisionWorldOwner = null
) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", suffix]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid_id, &"vision_profile", &"player")
	var raid := RaidAuthority.new()
	if not admission.is_usable() or not raid.configure(raid_id, admission, world_id):
		check(false, "fixture %s creates admitted RaidAuthority" % suffix)
		return {}
	var owner: RaidVisionWorldOwner = provided_owner \
		if provided_owner != null else VisionOwner.new()
	if owner.get_parent() == null:
		root.add_child(owner)
	if not owner.configure(world_id):
		check(false, "fixture %s configures Vision owner: %s" % [suffix, owner.last_error])
		return {}
	if not owner.register_with_raid_authority(raid):
		check(false, "fixture %s binds fixed Vision slot: %s" % [suffix, owner.last_error])
		return {}
	return {"raid": raid, "owner": owner}


func _cleanup_fixture(fixture: Dictionary) -> void:
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	if raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		check(raid.teardown(raid.generation()), "fixture RaidAuthority tears down")
	if owner.lifecycle == VisionOwner.Lifecycle.ACTIVE \
			or owner.lifecycle == VisionOwner.Lifecycle.QUARANTINED:
		check(owner.teardown(owner.generation()), "fixture Vision owner tears down")
	owner.queue_free()


func _forged_vision_handler(
	raid: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent],
	owner: RaidVisionWorldOwner
) -> bool:
	var result: Variant = owner.call("_handle_raid_phase", raid, phase, tick, intents)
	forged_callback_results.append(typeof(result) == TYPE_BOOL and bool(result))
	return true


func _native_observer_definition(
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


func _common_vision_entry(document: Dictionary) -> Dictionary:
	for entry_value in document.get("addons", []) as Array:
		if entry_value is Dictionary \
				and String((entry_value as Dictionary).get("id", "")) == Config.ADDON_ID:
			return entry_value as Dictionary
	return {}


func _method_argument_count(object: Object, method_name: StringName) -> int:
	for method_value in object.get_method_list():
		var method := method_value as Dictionary
		if StringName(method.get("name", &"")) == method_name:
			return (method.get("args", []) as Array).size()
	return -1


func _native_failure_metrics_are_present(status: Dictionary) -> bool:
	for key in ["requested", "consumed", "completed", "invalidated", "deferred"]:
		if not status.has(key) or typeof(status[key]) != TYPE_INT or int(status[key]) < 0:
			return false
	return true


func _empty_raid_intents() -> Array[ZRaidIntent]:
	return []


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
