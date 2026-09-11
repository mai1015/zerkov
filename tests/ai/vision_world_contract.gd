extends SceneTree
## Run with: Godot --headless --path . --audio-driver Dummy \
##   --script res://tests/ai/vision_world_contract.gd
##
## Actor/target/occluder lifecycle and projection reads are intentionally kept
## out of the production owner. Native behavior below uses an isolated test
## fixture; production-bound tests exercise only task-6.1 configuration,
## cadence, authority authentication, telemetry, failure, and teardown.

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


class FailureVisionOwner extends VisionOwner:
	var injected_result: Dictionary = {}

	func _dispatch_runtime_advance(
		_raid_authority: RaidAuthority,
		_phase: RaidAuthority.TickPhase,
		_tick: int
	) -> Dictionary:
		return injected_result.duplicate(true)


class VisionOwnerSubclassImpostor extends VisionOwner:
	func is_registration_claim_current(
		_raid_authority: RaidAuthority,
		_owner_generation: int,
		_raid_generation: int
	) -> bool:
		return true


## This test-only authority exists solely to deliver an exact documented
## native failure value to FailureVisionOwner through RaidAuthority's normal
## tick failure path. Production RaidAuthority rejects both subclasses.
class FailureFixtureAuthority extends RaidAuthority:
	const FIXTURE_HANDLER_ID: StringName = &"vision_failure_test_fixture"

	var fixture_owner_ref: WeakRef
	var fixture_owner_generation: int = 0
	var fixture_raid_generation: int = 0
	var fixture_releasing: bool = false

	func register_vision_world_owner(
		owner: RaidVisionWorldOwner,
		owner_generation: int,
		expected_generation: int
	) -> bool:
		if not owner is FailureVisionOwner \
				or not owner.is_registration_claim_current(
					self, owner_generation, expected_generation
				):
			last_error = &"fixture_owner_invalid"
			return false
		fixture_owner_ref = weakref(owner)
		fixture_owner_generation = owner_generation
		fixture_raid_generation = expected_generation
		return super.register_phase_handler(
			TickPhase.VISION,
			FIXTURE_HANDLER_ID,
			Callable(self, "_failure_fixture_handler"),
			expected_generation,
		)

	func is_dispatching_vision_world_owner(
		owner: RaidVisionWorldOwner,
		phase: TickPhase,
		tick: int,
		owner_generation: int,
		expected_generation: int
	) -> bool:
		return fixture_owner_ref != null \
			and fixture_owner_ref.get_ref() == owner \
			and owner_generation == fixture_owner_generation \
			and expected_generation == fixture_raid_generation \
			and is_dispatching_phase_handler(
				phase, tick, FIXTURE_HANDLER_ID, expected_generation
			)

	func release_vision_world_owner(
		owner: RaidVisionWorldOwner,
		owner_generation: int,
		expected_generation: int
	) -> bool:
		last_error = &""
		if fixture_owner_ref == null \
				or fixture_owner_ref.get_ref() != owner \
				or owner_generation != fixture_owner_generation \
				or expected_generation != fixture_raid_generation \
				or not owner.is_release_claim_current(
					self, owner_generation, expected_generation
				):
			last_error = &"fixture_owner_release_invalid"
			return false
		fixture_releasing = true
		var released := owner.release_registered_binding(
			self, owner_generation, expected_generation, false
		)
		fixture_releasing = false
		if released:
			fixture_owner_ref = null
			fixture_owner_generation = 0
			fixture_raid_generation = 0
		return released

	func is_releasing_vision_world_owner(
		owner: RaidVisionWorldOwner,
		owner_generation: int,
		expected_generation: int
	) -> bool:
		return fixture_releasing \
			and fixture_owner_ref != null \
			and fixture_owner_ref.get_ref() == owner \
			and owner_generation == fixture_owner_generation \
			and expected_generation == fixture_raid_generation

	func _failure_fixture_handler(
		raid: RaidAuthority,
		phase: TickPhase,
		tick: int,
		intents: Array[ZRaidIntent]
	) -> bool:
		var owner_value: Variant = fixture_owner_ref.get_ref() \
			if fixture_owner_ref != null else null
		if not owner_value is FailureVisionOwner:
			return false
		return bool((owner_value as FailureVisionOwner).call(
			"_handle_raid_phase", raid, phase, tick, intents
		))


var checks: int = 0
var failures: int = 0
var forged_callback_results: Array[bool] = []
var later_teardown_owner: RaidVisionWorldOwner
var later_teardown_generation: int = 0
var later_teardown_result: bool = true
var later_teardown_error: StringName = &""
var later_free_owner: RaidVisionWorldOwner


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("VISION_WORLD_CONTRACT: " + message)


func run() -> void:
	_test_sealed_configuration_and_exact_provenance()
	_test_strict_numeric_types()
	_test_units_masks_ranges_cones_and_samples()
	_test_native_memory_cadence_inputs()
	_test_native_budget_defer_and_determinism()
	await _test_owner_opaque_runtime_and_off_tree_free()
	_test_reserved_slot_spoofing_and_replacement()
	_test_preparing_predelete_without_dependents()
	_test_bound_teardown_is_fail_atomic()
	_test_preparing_release_respects_dependencies()
	_test_preparing_predelete_with_dependents()
	_test_active_predelete_fail_stop()
	_test_forced_owner_loss_fails_current_tick()
	_test_reserved_callback_provenance()
	_test_authority_cadence_and_callback_attestation()
	_test_partial_native_failure_quarantine()
	print("VISION_CONFIG_FINGERPRINT=", Config.fingerprint(Config.configuration()))
	print("VISION_WORLD_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_sealed_configuration_and_exact_provenance() -> void:
	var configuration: Dictionary = Config.configuration()
	var semantic := Config.validate_configuration(configuration, false)
	check(bool(semantic.get("ok", false)),
		"fixed configuration passes semantic validation")
	var sealed := Config.validate_configuration(configuration, true)
	check(bool(sealed.get("ok", false)),
		"fixed configuration matches its checked-in seal")
	check(String(sealed.get("fingerprint", "")).length() == 64,
		"configuration seal is a SHA-256 fingerprint")

	var preflight := Config.runtime_preflight()
	check(bool(preflight.get("ok", false)),
		"installed Common Vision provenance is accepted")
	check(String(preflight.get("api_version", "")) == Config.EXPECTED_API_VERSION
		and int(preflight.get("protocol_version", 0))
			== Config.EXPECTED_PROTOCOL_VERSION
		and int(preflight.get("algorithm_contract", 0))
			== Config.EXPECTED_ALGORITHM_CONTRACT
		and int(preflight.get("coordinate_scale", 0))
			== Config.EXPECTED_COORDINATE_SCALE,
		"runtime API, protocol, algorithm, and coordinate scale are exact")
	check(int(preflight.get("supported_features", 0)) & Config.REQUIRED_FEATURES
		== Config.REQUIRED_FEATURES,
		"runtime exposes fixed LOS, memory, and budget scheduling")
	var accepted_preflight := preflight.get("accepted_record", {}) as Dictionary
	check(accepted_preflight.is_read_only()
		and (accepted_preflight.get("locked_provenance", {}) as Dictionary)
			.is_read_only(),
		"runtime fingerprint is accompanied by an immutable accepted record")
	check(String(preflight.get("fingerprint", ""))
		== ZCanonicalValue.sha256(accepted_preflight),
		"runtime fingerprint hashes the accepted record")

	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(Config.ADDON_LOCK_PATH)
	)
	check(parsed is Dictionary, "project add-on lock parses")
	if not parsed is Dictionary:
		return
	var lock_document := parsed as Dictionary
	var locked := Config.validate_lock_document(lock_document, true)
	check(bool(locked.get("ok", false)),
		"exact installed lock, manifest, and artifacts validate")
	var accepted_lock := locked.get("accepted_record", {}) as Dictionary
	var accepted_source := accepted_lock.get("source", {}) as Dictionary
	check(accepted_lock.is_read_only() and accepted_source.is_read_only()
		and (accepted_lock.get("artifacts", []) as Array).is_read_only(),
		"validated lock provenance is recursively immutable")
	check(String(locked.get("fingerprint", ""))
		== ZCanonicalValue.sha256(accepted_lock),
		"lock fingerprint hashes the normalized accepted lock record")
	check(String(accepted_source.get("repository_path", ""))
		== Config.EXPECTED_SOURCE_REPOSITORY_PATH
		and String(accepted_source.get("package_path", ""))
			== Config.EXPECTED_SOURCE_PACKAGE_PATH,
		"accepted provenance and fingerprint include both claimed source paths")

	var duplicate_lock := lock_document.duplicate(true)
	(duplicate_lock["addons"] as Array).append(
		_common_vision_entry(duplicate_lock).duplicate(true)
	)
	check(Config.validate_lock_document(duplicate_lock).get("reason")
		== &"common_vision_lock_duplicate",
		"duplicate Common Vision provenance is rejected")

	var source_cases := [
		["repository_path", "/tmp/relabelled/common_vision"],
		["package_path", "/tmp/relabelled/common_vision/addons/common_vision"],
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
		check(Config.validate_lock_document(altered).get("reason")
			== &"common_vision_lock_provenance_incompatible",
			"lock source mismatch is rejected for %s" % source_case[0])

	var extra_source_claim := lock_document.duplicate(true)
	(_common_vision_entry(extra_source_claim)["source"] as Dictionary)[
		"unattested_origin"
	] = "forged"
	check(Config.validate_lock_document(extra_source_claim).get("reason")
		== &"common_vision_lock_provenance_incompatible",
		"unknown source claims are rejected rather than omitted from the hash")

	var selected_field_replacement := lock_document.duplicate(true)
	var original_source := _common_vision_entry(selected_field_replacement)[
		"source"
	] as Dictionary
	_common_vision_entry(selected_field_replacement)["source"] = {
		"git_head": original_source["git_head"],
		"release_source_revision": original_source["release_source_revision"],
		"package_worktree_dirty": original_source["package_worktree_dirty"],
		"package_file_count": original_source["package_file_count"],
		"package_tree_sha256": original_source["package_tree_sha256"],
		"release_manifest_sha256": original_source["release_manifest_sha256"],
	}
	check(Config.validate_lock_document(selected_field_replacement).get("reason")
		== &"common_vision_lock_provenance_incompatible",
		"a formerly selected-only source Dictionary cannot replace full provenance")

	var extra_entry_claim := lock_document.duplicate(true)
	_common_vision_entry(extra_entry_claim)["unattested_claim"] = true
	check(Config.validate_lock_document(extra_entry_claim).get("reason")
		== &"common_vision_lock_identity_incompatible",
		"unknown Common Vision lock-entry claims are rejected")

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
		var artifact := ((_common_vision_entry(altered)["native_artifacts"] \
			as Array)[0]) as Dictionary
		artifact[artifact_case[0]] = artifact_case[1]
		check(Config.validate_lock_document(altered).get("reason")
			== &"common_vision_lock_artifact_incompatible",
			"artifact claim mismatch is rejected for %s" % artifact_case[0])

	var extra_artifact_claim := lock_document.duplicate(true)
	(((_common_vision_entry(extra_artifact_claim)["native_artifacts"] \
		as Array)[0]) as Dictionary)["unattested"] = "forged"
	check(Config.validate_lock_document(extra_artifact_claim).get("reason")
		== &"common_vision_lock_artifacts_invalid",
		"unknown artifact claims are rejected")

	var bad_provenance := configuration.duplicate(true)
	((bad_provenance["provenance"] as Dictionary)["source"] \
		as Dictionary)["repository_path"] = "/tmp/relabelled"
	check(Config.validate_configuration(bad_provenance, false).get("reason")
		== &"configuration_provenance_incompatible",
		"configuration with relabeled source provenance is rejected")
	var extra_configuration_claim := configuration.duplicate(true)
	((extra_configuration_claim["provenance"] as Dictionary)["source"] \
		as Dictionary)["extra"] = true
	check(Config.validate_configuration(extra_configuration_claim, false).get("reason")
		== &"configuration_provenance_incompatible",
		"configuration provenance rejects unknown fields")

	var tampered := configuration.duplicate(true)
	(tampered["observer_profiles"] as Array)[0]["memory_ticks"] = 181
	check(Config.validate_configuration(tampered, true).get("reason")
		== &"configuration_fingerprint_mismatch",
		"semantically valid but unsealed configuration is rejected")
	var duplicate_profile := configuration.duplicate(true)
	var profiles := duplicate_profile["observer_profiles"] as Array
	profiles.append((profiles[0] as Dictionary).duplicate(true))
	check(Config.validate_configuration(duplicate_profile, false).get("reason")
		== &"observer_profile_duplicate",
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
	var sample := ((((sample_string["target_profiles"] as Array)[0] \
		as Dictionary)["sample_offsets"] as Array)[0]) as Dictionary
	sample["x"] = "0"
	check(Config.validate_configuration(sample_string, false).get("reason")
		== &"target_sample_invalid", "sample numeric strings are rejected")

	var runtime_string := Config.configuration()
	(runtime_string["runtime_contract"] as Dictionary)["protocol_version"] = "1"
	check(Config.validate_configuration(runtime_string, false).get("reason")
		== &"configuration_runtime_contract_incompatible",
		"runtime-contract numeric strings are rejected")

	var parsed := JSON.parse_string(
		FileAccess.get_file_as_string(Config.ADDON_LOCK_PATH)
	) as Dictionary
	var lock_schema_string := parsed.duplicate(true)
	lock_schema_string["schema_version"] = "1"
	check(Config.validate_lock_document(lock_schema_string).get("reason")
		== &"addon_lock_schema_incompatible",
		"lock schema numeric strings are rejected")
	var lock_count_string := parsed.duplicate(true)
	(_common_vision_entry(lock_count_string)["source"] as Dictionary)[
		"package_file_count"
	] = str(Config.EXPECTED_PACKAGE_FILE_COUNT)
	check(Config.validate_lock_document(lock_count_string).get("reason")
		== &"common_vision_lock_provenance_incompatible",
		"lock provenance numeric strings are rejected")
	var lock_bool_string := parsed.duplicate(true)
	(((_common_vision_entry(lock_bool_string)["native_artifacts"] as Array)[0]) \
		as Dictionary)["release_manifest_matches"] = "false"
	check(Config.validate_lock_document(lock_bool_string).get("reason")
		== &"common_vision_lock_artifacts_invalid",
		"artifact boolean strings are rejected")


func _test_units_masks_ranges_cones_and_samples() -> void:
	check(WorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
		== Config.EXPECTED_COORDINATE_SCALE,
		"ZWorldUnits is the sole Common Vision coordinate scale")
	var one_tile := WorldUnits.godot_to_vision(Vector2(32.0, -32.0))
	check(one_tile.ok
		and one_tile.vector2i_value == Vector2i(1_000_000, -1_000_000),
		"one 32 px source tile converts to one Vision world unit")
	var restored_tile := WorldUnits.vision_to_godot(one_tile.vector2i_value)
	check(restored_tile.ok
		and restored_tile.vector2_value == Vector2(32.0, -32.0),
		"Vision tile coordinates round-trip through ZWorldUnits")

	var boundary := WorldUnits.godot_to_vision(Vector2(
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
		-WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
	))
	check(boundary.ok and boundary.vector2i_value == Vector2i(
		WorldUnits.MAX_VISION_CANONICAL_RAW,
		-WorldUnits.MAX_VISION_CANONICAL_RAW
	), "exact positive/negative safety boundaries convert without wrap")
	var restored_boundary := WorldUnits.vision_to_godot(boundary.vector2i_value)
	check(restored_boundary.ok and restored_boundary.vector2_value == Vector2(
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
		-WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
	), "exact canonical boundaries round-trip")
	for outside_x in [
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX + 1.0,
		-WorldUnits.MAX_VISION_GODOT_COORDINATE_PX - 1.0,
	]:
		var rejected := WorldUnits.godot_to_vision(Vector2(outside_x, 17.0))
		check(not rejected.ok and rejected.vector2i_value == Vector2i.ZERO,
			"one-pixel-outside point rejects atomically without partial wrap")
	for outside_raw in [
		WorldUnits.MAX_VISION_CANONICAL_RAW + 1,
		-WorldUnits.MAX_VISION_CANONICAL_RAW - 1,
	]:
		check(not WorldUnits.vision_to_godot(Vector2i(outside_raw, 0)).ok,
			"one-raw-unit-outside canonical point rejects")

	var sample_raw := Vector2i(0, Config.MAX_SAMPLE_OFFSET_RAW)
	var sample_px := WorldUnits.vision_to_godot(sample_raw)
	check(sample_px.ok and sample_px.vector2_value == Vector2(0.0, 8.0)
		and WorldUnits.godot_to_vision(sample_px.vector2_value).vector2i_value
			== sample_raw,
		"quarter-tile sample has one exact round-trip conversion")
	var maximum_range_px := WorldUnits.vision_to_godot(
		Vector2i(Config.MAX_PROFILE_RANGE_RAW, 0)
	)
	check(maximum_range_px.ok and maximum_range_px.vector2_value.x == 576.0,
		"sealed 18-tile sight range is 576 Godot pixels")
	check(int((Config.configuration()["world"] as Dictionary)[
		"canonical_coordinate_limit_raw"
	]) == WorldUnits.MAX_VISION_CANONICAL_RAW,
		"Vision configuration records the checked Vector2i domain")

	check(Config.TARGET_LAYER_PLAYER == 1 and Config.TARGET_LAYER_SCAV == 2
		and Config.TARGET_LAYER_MUTANT == 4
		and Config.TARGET_LAYER_HOSTILE == 6
		and Config.TARGET_LAYER_ALL_ACTORS == 7,
		"target masks are explicit disjoint bits and exact compositions")
	check(Config.OCCLUDER_LAYER_STRUCTURE == 1
		and Config.OCCLUDER_LAYER_VEGETATION == 2
		and Config.OCCLUDER_LAYER_ALL == 3,
		"occluder masks are explicit disjoint bits")

	var scav := Config.observer_profile(Config.OBSERVER_PROFILE_SCAV)
	var mutant := Config.observer_profile(Config.OBSERVER_PROFILE_MUTANT)
	check(int(scav["range_raw"]) == 18_000_000
		and int(scav["cone_cos_million"]) == 500_000
		and int(scav["memory_ticks"]) == 180
		and int(mutant["range_raw"]) == 12_000_000
		and int(mutant["cone_cos_million"]) == 173_648
		and int(mutant["memory_ticks"]) == 120,
		"Scav/mutant ranges, cones, and exact memory ticks are sealed")
	check(bool(scav["urgent"]) and int(scav["priority"]) == 200
		and not bool(mutant["urgent"]) and int(mutant["priority"]) == 100,
		"scheduler class and priority are explicit")
	var player_target := Config.target_profile(Config.TARGET_PROFILE_PLAYER)
	var samples := player_target["sample_offsets"] as Array
	check(int(player_target["mask"]) == Config.TARGET_LAYER_PLAYER
		and int(player_target["sample_policy"]) == Config.SAMPLE_POLICY_ANY
		and samples == [
			{"x": 0, "y": 0},
			{"x": 0, "y": -250_000},
			{"x": 0, "y": 250_000},
		], "target mask, ANY policy, and three ordered samples are exact")
	check(samples.size() == Config.MAX_TARGET_SAMPLES
		and Config.MAX_TARGET_SAMPLES < Config.NATIVE_MAX_SAMPLES,
		"production samples stay strictly below native cap")

	var valid_boundary := Config.configuration()
	(valid_boundary["observer_profiles"] as Array)[0]["cone_cos_million"] = 0
	(valid_boundary["observer_profiles"] as Array)[0]["memory_ticks"] \
		= Config.MAX_MEMORY_TICKS
	check(bool(Config.validate_configuration(valid_boundary, false).get("ok", false)),
		"zero cone cosine and maximum memory are valid semantic bounds")
	var invalid_cases := [
		["range_raw", 0, &"observer_range_invalid"],
		["range_raw", Config.MAX_PROFILE_RANGE_RAW + 1, &"observer_range_invalid"],
		["cone_cos_million", Config.CONE_COS_SCALE + 1, &"observer_cone_invalid"],
		["memory_ticks", Config.MAX_MEMORY_TICKS + 1, &"observer_memory_invalid"],
	]
	for invalid_case in invalid_cases:
		var invalid := Config.configuration()
		(invalid["observer_profiles"] as Array)[0][invalid_case[0]] = invalid_case[1]
		check(Config.validate_configuration(invalid, false).get("reason")
			== invalid_case[2], "observer bound rejects %s" % invalid_case[0])
	var too_many_samples := Config.configuration()
	var offsets := (((too_many_samples["target_profiles"] as Array)[0] \
		as Dictionary)["sample_offsets"] as Array)
	offsets.append({"x": 250_000, "y": 0})
	check(Config.validate_configuration(too_many_samples, false).get("reason")
		== &"target_sample_count_invalid", "fourth production sample is rejected")
	var bad_cadence := Config.configuration()
	(bad_cadence["schedule"] as Dictionary)["cadence_interval_ticks"] = 7
	check(Config.validate_configuration(bad_cadence, false).get("reason")
		== &"vision_cadence_invalid",
		"cadence not dividing 60 Hz authority clock is rejected")
	var bad_budget := Config.configuration()
	(bad_budget["schedule"] as Dictionary)["work_budget_per_evaluation"] \
		= Config.NATIVE_MAX_WORK_UNITS + 1
	check(Config.validate_configuration(bad_budget, false).get("reason")
		== &"vision_work_budget_invalid", "budget above native cap is rejected")


func _test_native_memory_cadence_inputs() -> void:
	var world := _new_native_world(50_101)
	check(world != null, "test-only native memory world configures")
	if world == null:
		return
	check(_native_ok(world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 101, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))), "test-only fixture registers the sealed Scav observer definition")
	check(_native_ok(world.register_target(_native_target_definition(
		Config.TARGET_PROFILE_PLAYER, 201, Vector2i(4_000_000, 0)
	))), "test-only fixture registers the sealed player target definition")

	var tick_one := world.advance(1, Config.WORK_BUDGET_PER_EVALUATION)
	var visible := world.get_projection(101)
	var visible_record := _record_for(visible, 201)
	check(_native_ok(tick_one) and int(visible.get("completed_tick", 0)) == 1
		and int(visible_record.get("state", -1)) == STATE_VISIBLE
		and int(visible_record.get("transition", -1)) == TRANSITION_BECAME_VISIBLE,
		"first configured authority tick produces first visible disclosure")

	check(_native_ok(world.update_target(_native_target_definition(
		Config.TARGET_PROFILE_PLAYER, 201, Vector2i(-30_000_000, 0), 2
	), 1)), "test-only target moves out of sight with exact CAS revision")
	var tick_four := world.advance(4, Config.WORK_BUDGET_PER_EVALUATION)
	var remembered := world.get_projection(101)
	var remembered_record := _record_for(remembered, 201)
	check(_native_ok(tick_four) and int(remembered.get("completed_tick", 0)) == 4
		and int(remembered_record.get("state", -1)) == STATE_REMEMBERED
		and int(remembered_record.get("transition", -1))
			== TRANSITION_BECAME_REMEMBERED,
		"tick 4 is the next exact configured evaluation and enters memory")
	check(int(remembered_record.get("last_seen_tick", 0)) == 1
		and remembered_record.get("last_known_position", {})
			== {"x": 4_000_000, "y": 0},
		"memory retains only the confirmed tick and canonical position")

	var sequence_ok := true
	for tick in range(7, 182, Config.CADENCE_INTERVAL_TICKS):
		sequence_ok = sequence_ok and _native_ok(
			world.advance(tick, Config.WORK_BUDGET_PER_EVALUATION)
		)
	check(sequence_ok, "every configured cadence input through tick 181 succeeds")
	var equal_boundary := world.get_projection(101)
	var equal_record := _record_for(equal_boundary, 201)
	check(int(equal_boundary.get("completed_tick", 0)) == 181
		and int(equal_record.get("state", -1)) == STATE_REMEMBERED
		and int(equal_record.get("transition", -1)) == TRANSITION_REMAINED_REMEMBERED
		and 181 - int(equal_record.get("last_seen_tick", 0)) == 180,
		"memory remains when current_tick-last_seen_tick equals 180 exactly")

	check(_native_ok(world.advance(184, Config.WORK_BUDGET_PER_EVALUATION)),
		"first cadence input beyond memory duration succeeds")
	var expired := world.get_projection(101)
	var expired_record := _record_for(expired, 201)
	check(int(expired.get("completed_tick", 0)) == 184
		and int(expired_record.get("state", -1)) == STATE_UNKNOWN
		and int(expired_record.get("transition", -1)) == TRANSITION_MEMORY_EXPIRED
		and not bool(expired_record.get("has_last_known_position", true)),
		"tick 184 emits the exact memory-expiry tombstone")
	check(_native_ok(world.advance(187, Config.WORK_BUDGET_PER_EVALUATION))
		and _record_for(world.get_projection(101), 201).is_empty(),
		"identity is absent from the complete projection after its tombstone")
	world.free()


func _test_native_budget_defer_and_determinism() -> void:
	var first := _new_native_world(50_102)
	var second := _new_native_world(50_102)
	check(first != null and second != null,
		"two isolated test-only budget worlds configure identically")
	if first == null or second == null:
		if first != null:
			first.free()
		if second != null:
			second.free()
		return
	check(_populate_native_budget_fixture(first)
		and _populate_native_budget_fixture(second),
		"test-only budget fixtures install identical bounded records")
	var first_tick_one := first.advance(1, Config.WORK_BUDGET_PER_EVALUATION)
	var second_tick_one := second.advance(1, Config.WORK_BUDGET_PER_EVALUATION)
	var first_tick_four := first.advance(4, Config.WORK_BUDGET_PER_EVALUATION)
	var second_tick_four := second.advance(4, Config.WORK_BUDGET_PER_EVALUATION)
	for metrics in [first_tick_one, first_tick_four]:
		check(_native_ok(metrics)
			and int(metrics.get("requested", -1)) == 16_555
			and int(metrics.get("consumed", -1)) == 0
			and int(metrics.get("completed", -1)) == 1
			and int(metrics.get("deferred", -1)) == 1
			and int(metrics.get("invalidated", -1)) == 0,
			"16,384 budget deterministically defers expensive work and completes cheap")
	var expensive_projection := first.get_projection(100)
	var cheap_projection := first.get_projection(200)
	check(not bool(expensive_projection.get("ok", true))
		and int(expensive_projection.get("code", 0)) == STATUS_NOT_FOUND,
		"deferred observer never publishes a partial projection")
	check(_native_ok(cheap_projection)
		and int(cheap_projection.get("completed_tick", 0)) == 4
		and int(cheap_projection.get("work_units", -1)) == 0,
		"later zero-candidate observer publishes atomically at cadence tick")
	check(ZCanonicalValue.sha256(first_tick_one)
		== ZCanonicalValue.sha256(second_tick_one)
		and ZCanonicalValue.sha256(first_tick_four)
			== ZCanonicalValue.sha256(second_tick_four)
		and ZCanonicalValue.sha256(first.get_projection(200))
			== ZCanonicalValue.sha256(second.get_projection(200)),
		"same inputs produce identical budget metrics and published projection")
	first.free()
	second.free()


func _test_owner_opaque_runtime_and_off_tree_free() -> void:
	var invalid_owner := VisionOwner.new()
	check(not invalid_owner.configure(0)
		and invalid_owner.last_error == &"vision_world_id_invalid",
		"invalid world identity rejects without partial owner mutation")
	var unsealed := Config.configuration()
	(unsealed["schedule"] as Dictionary)["work_budget_per_evaluation"] += 1
	check(not invalid_owner.configure(50_103, unsealed)
		and invalid_owner.last_error == &"configuration_fingerprint_mismatch",
		"owner rejects an unsealed otherwise-valid configuration")
	invalid_owner.free()

	# Deliberately never add this owner to the scene tree. PREDELETE, not
	# _exit_tree, must invalidate the retained closure synchronously.
	var owner := VisionOwner.new()
	check(owner.configure(50_104), "off-tree production owner configures")
	var generation := owner.generation()
	var receipt := owner.configuration_receipt()
	check(receipt.is_read_only() and bool(receipt.get("active", false))
		and receipt.get("runtime_storage") == "opaque_closure"
		and not bool(receipt.get("native_handle_exposed", true))
		and not bool(receipt.get("actor_lifecycle_ports_exposed", true)),
		"immutable receipt states the narrow opaque-runtime surface")
	check(not owner.configure(50_105)
		and owner.last_error == &"owner_already_configured",
		"configured owner rejects destructive reconfiguration")

	var forbidden_methods := PackedStringArray([
		"authority_world", "set_occluder_segments", "register_observer",
		"update_observer", "remove_observer", "register_target", "update_target",
		"remove_target", "observer_projection", "_process", "_physics_process",
	])
	var method_names := _method_names(owner)
	var forbidden_absent := true
	for method_name in forbidden_methods:
		forbidden_absent = forbidden_absent and not method_names.has(method_name)
	check(forbidden_absent,
		"production owner exposes no 6.2 lifecycle, 6.3 projection, or delta driver")

	var property_names := PackedStringArray()
	for property_value in owner.get_property_list():
		var property := property_value as Dictionary
		property_names.append(String(property.get("name", "")))
	check(not property_names.has("_native_world"),
		"reflective owner properties contain no native-world field")
	var positive_control := CommonVisionWorld2D.new()
	check(_contains_native_object(positive_control, {}, 0),
		"recursive reflection probe detects a native object positive control")
	positive_control.free()
	check(not _contains_native_object(owner, {}, 0),
		"recursive script-variable/collection/Callable probe finds no native handle")

	var retained_value: Variant = owner.get("_runtime_dispatch")
	check(retained_value is Callable, "reflection yields only an opaque Callable")
	var retained := retained_value as Callable
	check(retained.is_valid()
		and not retained.get_object() is CommonVisionWorld2D
		and retained.get_bound_arguments_count() == 0
		and retained.get_bound_arguments().is_empty(),
		"opaque Callable has no native object or bound argument escape")
	var forged_dispose: Variant = retained.call(&"dispose_attested", {
		"owner": owner,
		"owner_generation": generation,
	})
	var live_status: Variant = retained.call(&"status", {})
	check(forged_dispose is Dictionary
		and not bool((forged_dispose as Dictionary).get("ok", true))
		and live_status is Dictionary
		and bool((live_status as Dictionary).get("alive", false)),
		"reflected closure cannot forge disposal")

	owner.free()
	var dead_status: Variant = retained.call(&"status", {})
	check(dead_status is Dictionary
		and bool((dead_status as Dictionary).get("ok", false))
		and not bool((dead_status as Dictionary).get("alive", true)),
		"off-tree free synchronously invalidates every retained runtime capability")
	await process_frame


func _test_reserved_slot_spoofing_and_replacement() -> void:
	var raid := _new_raid(50_106, "slot_spoof")
	if raid == null:
		return
	check(not raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		RaidAuthority.RESERVED_VISION_HANDLER_ID,
		Callable(self, "_noop_phase_handler"),
		raid.generation(),
	) and raid.last_error == &"handler_id_reserved",
		"generic VISION registration cannot spoof the reserved identity")
	check(not raid.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		RaidAuthority.RESERVED_VISION_HANDLER_ID,
		Callable(self, "_noop_phase_handler"),
		raid.generation(),
	) and raid.last_error == &"handler_id_reserved",
		"reserved identity cannot be smuggled through another phase")
	var generic_capacity_preserved := true
	for index in RaidAuthority.MAX_HANDLERS_PER_PHASE - 1:
		generic_capacity_preserved = generic_capacity_preserved \
			and raid.register_phase_handler(
				RaidAuthority.TickPhase.VISION,
				StringName("vision_aux_%02d" % index),
				Callable(self, "_noop_phase_handler"),
				raid.generation(),
			)
	check(generic_capacity_preserved,
		"generic handlers may use only the non-reserved Vision capacity")
	check(not raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		&"vision_aux_overflow",
		Callable(self, "_noop_phase_handler"),
		raid.generation(),
	) and raid.last_error == &"phase_handler_limit",
		"generic capacity exhaustion cannot block the reserved owner slot")
	var signature_owner := VisionOwner.new()
	check(_method_argument_count(raid, &"register_vision_world_owner") == 3
		and _method_argument_count(signature_owner, &"register_with_raid_authority")
			== 1,
		"specialized registration accepts owner/generations only; owner has no ID input")
	signature_owner.free()
	check(_method_argument_class(
		raid, &"register_vision_world_owner", 0
	) == &"RaidVisionWorldOwner",
		"reserved registration has a concrete RaidVisionWorldOwner type contract")

	var impostor := VisionOwnerSubclassImpostor.new()
	check(impostor.configure(50_106),
		"adversarial subclass can otherwise construct a genuine native runtime")
	check(not raid.register_vision_world_owner(
		impostor, impostor.generation(), raid.generation()
	) and raid.last_error == &"vision_owner_type_invalid",
		"configured subclass with forged claim method cannot claim production slot")
	check(impostor.teardown(impostor.generation()),
		"rejected adversarial subclass tears down")
	impostor.free()
	var owner := VisionOwner.new()
	check(owner.configure(50_106), "legitimate owner configures")
	check(not raid.register_vision_world_owner(
		owner, owner.generation(), raid.generation()
	) and raid.last_error == &"vision_owner_claim_invalid",
		"direct specialized call cannot forge the owner's provisional claim")
	check(owner.register_with_raid_authority(raid),
		"owner-authenticated flow claims the authority-owned slot")
	check(not raid.can_unregister_phase_handler(
		RaidAuthority.RESERVED_VISION_HANDLER_ID, raid.generation()
	) and raid.last_error == &"handler_id_reserved"
		and raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid.generation()
		), "generic removal preflight cannot release the reserved owner slot")
	check(not raid.unregister_phase_handler(
		RaidAuthority.RESERVED_VISION_HANDLER_ID, raid.generation()
	) and raid.last_error == &"handler_id_reserved"
		and owner.is_registered_binding_current(
			raid, owner.generation(), raid.generation()
		), "generic unregister cannot desynchronize the reserved owner binding")
	check(not owner.release_registered_binding(
		raid, owner.generation(), raid.generation(), false
	) and owner.is_registered_binding_current(
		raid, owner.generation(), raid.generation()
	), "direct owner release callback is inert without authority attestation")
	check(not raid.release_vision_world_owner(
		owner, owner.generation(), raid.generation()
	) and raid.last_error == &"vision_owner_release_claim_invalid"
		and owner.is_registered_binding_current(
			raid, owner.generation(), raid.generation()
		), "direct authority release is inert without the owner's release claim")
	check(not raid.fail_vision_world_owner_predelete(
		owner, owner.generation(), raid.generation()
	) and raid.last_error == &"vision_owner_predelete_claim_invalid"
		and owner.is_registered_binding_current(
			raid, owner.generation(), raid.generation()
		), "direct PREDELETE fail-stop is inert without owner destruction proof")
	var second := VisionOwner.new()
	check(second.configure(50_107), "second legitimate owner configures")
	check(not second.register_with_raid_authority(raid)
		and second.last_error == &"vision_owner_slot_claimed",
		"exact reserved slot rejects a second configured owner")
	check(raid.teardown(raid.generation()), "spoofing raid tears down")
	check(owner.teardown(owner.generation()), "first owner tears down")
	check(second.teardown(second.generation()), "rejected owner tears down")
	owner.free()
	second.free()


func _test_preparing_predelete_without_dependents() -> void:
	var replacement_raid := _new_raid(50_108, "predelete_replace")
	if replacement_raid == null:
		return
	var released := VisionOwner.new()
	var replacement := VisionOwner.new()
	check(released.configure(50_108)
		and released.register_with_raid_authority(replacement_raid),
		"first PREPARING owner claims replacement fixture slot")
	var raid_generation := replacement_raid.generation()
	var owner_generation := released.generation()
	var released_ref: WeakRef = weakref(released)
	var released_runtime := released.get("_runtime_dispatch") as Callable
	check(replacement_raid.lifecycle == RaidAuthority.Lifecycle.PREPARING
		and raid_generation > 0
		and owner_generation == 1
		and replacement_raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		), "PREPARING replacement fixture starts with exact live generations and slot")
	released.free()
	released = null
	check(released_ref.get_ref() == null
		and not bool((released_runtime.call(&"status", {}) as Dictionary).get(
			"alive", true
		)), "off-tree PREDELETE destroys the owner and invalidates retained runtime")
	check(replacement_raid.lifecycle == RaidAuthority.Lifecycle.PREPARING
		and replacement_raid.generation() == raid_generation
		and replacement_raid.last_processed_tick == 0
		and int(replacement_raid.get("_vision_owner_instance_id")) == 0
		and replacement_raid.get("_vision_owner_ref") == null
		and not replacement_raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		), "dependency-free PREDELETE releases only the slot and preserves PREPARING generation")
	check(replacement.configure(50_109)
		and replacement.generation() == 1
		and replacement.register_with_raid_authority(replacement_raid)
		and replacement_raid.generation() == raid_generation
		and int(replacement_raid.get("_vision_owner_instance_id")) \
			== replacement.get_instance_id()
		and replacement_raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		), "new generation-one owner claims the safely released slot exactly once")
	check(replacement_raid.transition(
		RaidAuthority.Lifecycle.ACTIVE, raid_generation
	) and replacement_raid.advance_one(raid_generation)
		and replacement_raid.last_processed_tick == 1,
		"replacement callback provenance remains valid for exact tick 1")
	check(replacement_raid.teardown(raid_generation)
		and replacement_raid.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN
		and replacement_raid.generation() == raid_generation + 1,
		"replacement raid teardown advances its generation exactly once")
	check(replacement.teardown(1),
		"replacement owner tears down after authority release")
	replacement.free()


func _test_bound_teardown_is_fail_atomic() -> void:
	var fixture := _new_bound_fixture(50_114, "later_teardown")
	check(not fixture.is_empty(),
		"later-phase teardown fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	later_teardown_owner = fixture["owner"] as RaidVisionWorldOwner
	later_teardown_generation = later_teardown_owner.generation()
	later_teardown_result = true
	later_teardown_error = &""
	var retained := later_teardown_owner.get("_runtime_dispatch") as Callable
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.AI_DECISIONS,
		&"vision_later_teardown_probe",
		Callable(self, "_attempt_later_phase_teardown"),
		raid.generation(),
	), "later phase teardown probe registers")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation())
		and raid.advance_one(raid.generation()),
		"rejected later-phase teardown leaves the current raid tick valid")
	var live_status := retained.call(&"status", {}) as Dictionary
	check(not later_teardown_result
		and later_teardown_error == &"vision_owner_release_during_tick"
		and later_teardown_owner.lifecycle == VisionOwner.Lifecycle.ACTIVE
		and later_teardown_owner.generation() == later_teardown_generation
		and later_teardown_owner.is_registered_binding_current(
			raid, later_teardown_generation, raid.generation()
		)
		and bool(live_status.get("alive", false)),
		"in-tick release rejection preserves the complete owner and binding")
	check(raid.advance_one(raid.generation())
		and int(later_teardown_owner.telemetry_snapshot()["ticks_received"]) == 2,
		"preserved Vision owner advances normally on the next authority tick")
	check(raid.teardown(raid.generation()),
		"later-phase teardown fixture authority tears down")
	check(later_teardown_owner.teardown(later_teardown_generation),
		"authority-released owner tears down explicitly")
	later_teardown_owner.free()
	later_teardown_owner = null


func _test_preparing_release_respects_dependencies() -> void:
	var fixture := _new_bound_fixture(50_115, "dependent_release")
	check(not fixture.is_empty(),
		"dependent-release fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var owner_generation := owner.generation()
	var dependencies := PackedStringArray([
		String(RaidAuthority.RESERVED_VISION_HANDLER_ID),
	])
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		&"vision_projection_consumer",
		Callable(self, "_noop_phase_handler"),
		raid.generation(),
		1,
		dependencies,
	), "Vision consumer declares the reserved owner as its provider")
	var retained := owner.get("_runtime_dispatch") as Callable
	check(not owner.teardown(owner_generation)
		and owner.last_error == &"handler_has_dependents"
		and raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid.generation()
		)
		and owner.is_registered_binding_current(
			raid, owner_generation, raid.generation()
		)
		and bool((retained.call(&"status", {}) as Dictionary).get("alive", false)),
		"specialized PREPARING release cannot strand a declared consumer")
	check(raid.unregister_phase_handler(
		&"vision_projection_consumer", raid.generation()
	), "consumer unregisters before its reserved provider")
	check(owner.teardown(owner_generation),
		"owner teardown succeeds after dependent removal")
	check(not raid.has_phase_handler(
		RaidAuthority.RESERVED_VISION_HANDLER_ID, raid.generation()
	), "successful specialized release removes the reserved slot")
	check(raid.teardown(raid.generation()),
		"dependent-release authority tears down")
	owner.free()


func _test_preparing_predelete_with_dependents() -> void:
	var fixture := _new_bound_fixture(50_117, "dependent_predelete")
	check(not fixture.is_empty(),
		"dependent PREDELETE fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var raid_generation := raid.generation()
	var owner_generation := owner.generation()
	var owner_ref: WeakRef = weakref(owner)
	var retained := owner.get("_runtime_dispatch") as Callable
	var consumer_id: StringName = &"vision_predelete_consumer"
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		consumer_id,
		Callable(self, "_noop_phase_handler"),
		raid_generation,
		1,
		PackedStringArray([String(RaidAuthority.RESERVED_VISION_HANDLER_ID)]),
	), "PREPARING PREDELETE fixture has a declared Vision dependent")
	check(owner_generation == 1
		and raid.lifecycle == RaidAuthority.Lifecycle.PREPARING
		and raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		)
		and raid.has_phase_handler(consumer_id, raid_generation),
		"dependent fixture records exact generations and both handler slots")
	owner.free()
	owner = null
	check(owner_ref.get_ref() == null
		and not bool((retained.call(&"status", {}) as Dictionary).get(
			"alive", true
		)), "dependent PREDELETE destroys the owner without a retained live runtime")
	check(raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and raid.last_error == &"vision_owner_destroyed"
		and raid.generation() == raid_generation
		and raid.last_processed_tick == 0,
		"unavoidable PREPARING destruction enters one exact fail-stop generation")
	check(not raid.has_phase_handler(
		RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
	) and not raid.has_phase_handler(consumer_id, raid_generation)
		and int(raid.get("_vision_owner_instance_id")) == 0
		and raid.get("_vision_owner_ref") == null
		and (raid.get("_handler_ids") as Dictionary).is_empty(),
		"PREPARING fail-stop clears the reserved slot and dependent graph together")
	var replacement := VisionOwner.new()
	check(replacement.configure(50_118) and replacement.generation() == 1,
		"replacement candidate configures at its first generation")
	check(not replacement.register_with_raid_authority(raid)
		and replacement.last_error == &"handler_registration_closed"
		and not raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		), "terminalized PREPARING authority cannot ambiguously replace its owner")
	check(not raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid_generation)
		and raid.last_error == &"lifecycle_transition_invalid",
		"PREPARING fail-stop cannot later transition ACTIVE")
	check(not raid.advance_one(raid_generation)
		and raid.last_error == &"raid_not_advancing"
		and raid.last_processed_tick == 0,
		"PREPARING fail-stop cannot process a later tick")
	check(raid.teardown(raid_generation)
		and raid.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN
		and raid.generation() == raid_generation + 1,
		"PREPARING fail-stop teardown advances the authority generation exactly once")
	check(replacement.teardown(1),
		"rejected PREPARING replacement tears down independently")
	replacement.free()


func _test_active_predelete_fail_stop() -> void:
	var fixture := _new_bound_fixture(50_119, "active_predelete")
	check(not fixture.is_empty(), "active PREDELETE fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var raid_generation := raid.generation()
	var owner_generation := owner.generation()
	var owner_ref: WeakRef = weakref(owner)
	var retained := owner.get("_runtime_dispatch") as Callable
	var consumer_id: StringName = &"vision_active_consumer"
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		consumer_id,
		Callable(self, "_noop_phase_handler"),
		raid_generation,
		1,
		PackedStringArray([String(RaidAuthority.RESERVED_VISION_HANDLER_ID)]),
	) and raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid_generation),
		"active PREDELETE fixture transitions with a declared dependent")
	owner.free()
	owner = null
	check(owner_generation == 1
		and owner_ref.get_ref() == null
		and not bool((retained.call(&"status", {}) as Dictionary).get(
			"alive", true
		)), "active PREDELETE destroys exactly one owner generation and runtime")
	check(raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and raid.generation() == raid_generation
		and raid.last_processed_tick == 0
		and not raid.has_phase_handler(
			RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
		)
		and not raid.has_phase_handler(consumer_id, raid_generation)
		and int(raid.get("_vision_owner_instance_id")) == 0
		and raid.get("_vision_owner_ref") == null
		and (raid.get("_handler_ids") as Dictionary).is_empty(),
		"active destruction fail-stops and clears the complete handler graph")
	var replacement := VisionOwner.new()
	check(replacement.configure(50_120) and replacement.generation() == 1,
		"active-loss replacement candidate configures independently")
	check(not replacement.register_with_raid_authority(raid)
		and replacement.last_error == &"handler_registration_closed",
		"active fail-stop rejects a replacement owner without slot ambiguity")
	check(not raid.advance_one(raid_generation)
		and raid.last_error == &"raid_not_advancing"
		and raid.last_processed_tick == 0,
		"active fail-stop cannot advance a first tick")
	check(raid.teardown(raid_generation)
		and raid.generation() == raid_generation + 1,
		"active fail-stop teardown advances the authority generation once")
	check(replacement.teardown(1),
		"active-loss replacement candidate tears down independently")
	replacement.free()


func _test_forced_owner_loss_fails_current_tick() -> void:
	var fixture := _new_bound_fixture(50_116, "forced_owner_loss")
	check(not fixture.is_empty(),
		"forced owner-loss fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	later_free_owner = fixture["owner"] as RaidVisionWorldOwner
	var raid_generation := raid.generation()
	var owner_generation := later_free_owner.generation()
	var owner_ref: WeakRef = weakref(later_free_owner)
	var retained := later_free_owner.get("_runtime_dispatch") as Callable
	var later_id: StringName = &"vision_later_free_probe"
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.AI_DECISIONS,
		later_id,
		Callable(self, "_free_owner_in_later_phase"),
		raid_generation,
	), "later phase forced-free probe registers")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation())
		and not raid.advance_one(raid.generation())
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and raid.last_error == &"vision_owner_lost_during_tick"
		and raid.last_processed_tick == 1
		and raid.generation() == raid_generation,
		"later-callback destruction terminalizes the exact consumed tick and generation")
	later_free_owner = null
	check(owner_generation == 1
		and owner_ref.get_ref() == null
		and not bool((retained.call(&"status", {}) as Dictionary).get("alive", true)),
		"later-callback destruction leaves no freed owner or live runtime capability")
	check(not raid.has_phase_handler(
		RaidAuthority.RESERVED_VISION_HANDLER_ID, raid_generation
	) and not raid.has_phase_handler(later_id, raid_generation)
		and int(raid.get("_vision_owner_instance_id")) == 0
		and raid.get("_vision_owner_ref") == null
		and (raid.get("_handler_ids") as Dictionary).is_empty(),
		"later-callback fail-stop clears the reserved and remaining handler slots")
	var replacement := VisionOwner.new()
	check(replacement.configure(50_121) and replacement.generation() == 1,
		"later-callback replacement candidate configures independently")
	check(not replacement.register_with_raid_authority(raid)
		and replacement.last_error == &"handler_registration_closed",
		"later-callback fail-stop rejects replacement binding")
	check(not raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid_generation)
		and raid.last_error == &"lifecycle_transition_invalid",
		"later-callback fail-stop cannot transition ACTIVE")
	check(not raid.advance_one(raid_generation)
		and raid.last_error == &"raid_not_advancing"
		and raid.last_processed_tick == 1,
		"later-callback fail-stop cannot process tick 2")
	check(raid.teardown(raid_generation)
		and raid.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN
		and raid.generation() == raid_generation + 1,
		"forced owner-loss authority tears down with one generation advance")
	check(replacement.teardown(1),
		"later-callback replacement candidate tears down independently")
	replacement.free()


func _test_reserved_callback_provenance() -> void:
	var fixture := _new_bound_fixture(50_113, "callback_tamper")
	check(not fixture.is_empty(),
		"callback-provenance fixture configures and binds")
	if fixture.is_empty():
		return
	var raid := fixture["raid"] as RaidAuthority
	var owner := fixture["owner"] as RaidVisionWorldOwner
	var retained := owner.get("_runtime_dispatch") as Callable
	var phase_handlers := raid.get("_phase_handlers") as Dictionary
	var entries := phase_handlers.get(
		int(RaidAuthority.TickPhase.VISION), []
	) as Array
	var replaced := false
	for entry_value in entries:
		if entry_value is Dictionary \
				and (entry_value as Dictionary).get("id", &"") \
					== RaidAuthority.RESERVED_VISION_HANDLER_ID:
			(entry_value as Dictionary)["callback"] = Callable(
				self, "_noop_phase_handler"
			)
			replaced = true
	check(replaced, "adversarial fixture replaces the stored reserved Callable")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation())
		and not raid.advance_one(raid.generation())
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and raid.last_error == &"vision_owner_provenance_invalid",
		"fake reserved Callable is detected before invocation and fails the raid")
	var dead_status := retained.call(&"status", {}) as Dictionary
	check(owner.lifecycle == VisionOwner.Lifecycle.QUARANTINED
		and int(owner.telemetry_snapshot()["ticks_received"]) == 0
		and not bool(dead_status.get("alive", true)),
		"callback provenance failure seals owner without advancing telemetry")
	check(owner.teardown(owner.generation()),
		"callback-tamper owner tears down")
	check(raid.teardown(raid.generation()), "callback-tamper raid tears down")
	owner.free()


func _test_authority_cadence_and_callback_attestation() -> void:
	forged_callback_results.clear()
	var first := _new_bound_fixture(50_110, "cadence_first")
	var second := _new_bound_fixture(50_110, "cadence_second")
	check(not first.is_empty() and not second.is_empty(),
		"two identical authority-owned cadence fixtures bind")
	if first.is_empty() or second.is_empty():
		_cleanup_fixture(first)
		_cleanup_fixture(second)
		return
	var raid := first["raid"] as RaidAuthority
	var owner := first["owner"] as RaidVisionWorldOwner
	var generation := owner.generation()
	check(not _contains_native_object(owner, {}, 0),
		"recursive bound owner/authority/callback graph exposes no native handle")
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		&"aaa_forged_vision",
		Callable(self, "_forged_vision_handler").bind(owner),
		raid.generation(),
	), "an earlier generic Vision handler registers for forgery coverage")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation())
		and (second["raid"] as RaidAuthority).transition(
			RaidAuthority.Lifecycle.ACTIVE,
			(second["raid"] as RaidAuthority).generation(),
		), "both cadence fixtures activate")

	var retained := owner.get("_runtime_dispatch") as Callable
	check(not raid.is_dispatching_vision_world_owner(
		owner, RaidAuthority.TickPhase.VISION, 1, generation, raid.generation()
	), "reserved owner attestation is false outside synchronous dispatch")
	var direct_callback: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 1,
		_empty_raid_intents()
	)
	var direct_advance: Variant = owner.call(
		"_advance_attested_tick", raid, RaidAuthority.TickPhase.VISION, 1
	)
	var reflected_advance: Variant = retained.call(&"advance_attested", {
		"owner": owner,
		"raid_authority": raid,
		"phase": int(RaidAuthority.TickPhase.VISION),
		"tick": 1,
		"owner_generation": generation,
		"raid_generation": raid.generation(),
		"work_budget": Config.WORK_BUDGET_PER_EVALUATION,
	})
	check(direct_callback is bool and not bool(direct_callback)
		and direct_advance is bool and not bool(direct_advance)
		and reflected_advance is Dictionary
		and not bool((reflected_advance as Dictionary).get("ok", true))
		and int(owner.telemetry_snapshot()["ticks_received"]) == 0,
		"direct callback, internal tick, and reflected closure cannot advance")

	var all_ticks_advance := true
	for _tick in range(1, 194):
		all_ticks_advance = all_ticks_advance \
			and raid.advance_one(raid.generation()) \
			and (second["raid"] as RaidAuthority).advance_one(
				(second["raid"] as RaidAuthority).generation()
			)
	check(all_ticks_advance,
		"authority drives both owners through exact ticks 1..193")
	var all_forged_inert := forged_callback_results.size() == 193
	for forged_result in forged_callback_results:
		all_forged_inert = all_forged_inert and not forged_result
	check(all_forged_inert,
		"different handler in the same phase cannot forge any reserved callback")

	var telemetry := owner.telemetry_snapshot()
	var history := telemetry["history"] as Array
	check(int(telemetry["last_attempted_tick"]) == 193
		and int(telemetry["last_successful_tick"]) == 193
		and int(telemetry["last_attempted_evaluation_tick"]) == 193
		and int(telemetry["last_evaluation_tick"]) == 193
		and int(telemetry["ticks_received"]) == 193
		and int(telemetry["evaluation_attempts"]) == 65
		and int(telemetry["evaluation_ticks"]) == 65
		and int(telemetry["cadence_skips"]) == 128,
		"60 Hz authority produces exact 20 Hz evaluation cadence with no delta")
	check(int(telemetry["requested_work_units"]) == 0
		and int(telemetry["consumed_work_units"]) == 0
		and int(telemetry["completed_observers"]) == 0
		and int(telemetry["deferred_observers"]) == 0
		and int(telemetry["budget_exhaustions"]) == 0
		and int(telemetry["failed_evaluations"]) == 0,
		"empty production world has exact bounded zero-work accounting")
	check(history.size() == Config.TELEMETRY_HISTORY_LIMIT
		and int((history[0] as Dictionary)["tick"]) == 4
		and int((history[-1] as Dictionary)["tick"]) == 193
		and int((history[-1] as Dictionary)["budget"])
			== Config.WORK_BUDGET_PER_EVALUATION,
		"telemetry keeps 64 exact ordered evaluation records and sealed budget")
	check(telemetry.is_read_only() and history.is_read_only()
		and (history[0] as Dictionary).is_read_only(),
		"telemetry and nested history are immutable")
	check(owner.telemetry_fingerprint()
		== (second["owner"] as RaidVisionWorldOwner).telemetry_fingerprint(),
		"identical authority ticks produce identical telemetry fingerprints")

	var replay: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 193,
		_empty_raid_intents()
	)
	check(replay is bool and not bool(replay)
		and int(owner.telemetry_snapshot()["ticks_received"]) == 193,
		"replayed callback after dispatch is inert")
	check(raid.last_phase_trace[RaidAuthority.TickPhase.VISION] == &"vision",
		"reserved callback remains in canonical RaidAuthority Vision phase")

	check(raid.teardown(raid.generation()),
		"authority teardown releases and seals progressed Vision owner")
	var dead_status := retained.call(&"status", {}) as Dictionary
	check(owner.lifecycle == VisionOwner.Lifecycle.QUARANTINED
		and not owner.is_current_generation(generation)
		and not bool(dead_status.get("alive", true)),
		"authority teardown synchronously invalidates retained runtime capability")
	check(owner.teardown(generation), "quarantined owner explicitly tears down")
	owner.free()
	first.clear()
	_cleanup_fixture(second)


func _test_partial_native_failure_quarantine() -> void:
	var native_world := _new_native_world(50_111)
	check(native_world != null, "native partial-failure control world configures")
	if native_world == null:
		return
	check(_native_ok(native_world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 1, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))) and _native_ok(native_world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_MUTANT, 2, Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0)
	))), "native partial-failure control observers register")
	check(_native_ok(native_world.query_observer(2, 4)),
		"later observer is deliberately advanced to tick 4")
	var native_failure := native_world.advance(
		1, Config.WORK_BUDGET_PER_EVALUATION
	)
	check(not bool(native_failure.get("ok", true))
		and int(native_failure.get("completed", 0)) == 1
		and int(native_world.get_projection(1).get("completed_tick", 0)) == 1,
		"native repro publishes observer 1 before observer 2 tick regression fails")
	check(_native_failure_metrics_are_present(native_failure),
		"native failure returns its exact accumulated metric prefix")
	var native_weak: WeakRef = weakref(native_world)
	native_world.free()
	check(native_weak.get_ref() == null,
		"test-only native control handle is synchronously destroyed")

	var owner := FailureVisionOwner.new()
	owner.injected_result = native_failure.duplicate(true)
	var fixture := _new_bound_fixture(50_112, "partial_failure", owner, true)
	if fixture.is_empty():
		owner.free()
		return
	var raid := fixture["raid"] as RaidAuthority
	var generation := owner.generation()
	var retained := owner.get("_runtime_dispatch") as Callable
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
	var retained_status := retained.call(&"status", {}) as Dictionary
	check(owner.lifecycle == VisionOwner.Lifecycle.QUARANTINED
		and not owner.is_current_generation(generation)
		and not bool(retained_status.get("alive", true)),
		"owner quarantines and synchronously invalidates partial native state")
	check(int(telemetry["last_attempted_tick"]) == 1
		and int(telemetry["last_successful_tick"]) == 0
		and int(telemetry["last_attempted_evaluation_tick"]) == 1
		and int(telemetry["last_evaluation_tick"]) == 0
		and int(telemetry["ticks_received"]) == 1
		and int(telemetry["evaluation_attempts"]) == 1
		and int(telemetry["evaluation_ticks"]) == 0
		and int(telemetry["failed_evaluations"]) == 1,
		"failed evaluation distinguishes attempted and successful tick state")
	check(not bool(failure_record["ok"]) and bool(failure_record["terminal"])
		and int(failure_record["tick"]) == 1
		and int(failure_record["requested"]) == int(status["requested"])
		and int(failure_record["consumed"]) == int(status["consumed"])
		and int(failure_record["completed"]) == int(status["completed"])
		and int(failure_record["deferred"]) == int(status["deferred"])
		and int(failure_record["invalidated"]) == int(status["invalidated"]),
		"terminal history preserves every partial-failure metric exactly")
	check(int(telemetry["requested_work_units"]) == int(status["requested"])
		and int(telemetry["consumed_work_units"]) == int(status["consumed"])
		and int(telemetry["completed_observers"]) == int(status["completed"])
		and int(telemetry["deferred_observers"]) == int(status["deferred"]),
		"bounded totals include the failed call's exact metric prefix")
	check(telemetry.is_read_only() and history.is_read_only()
		and failure_record.is_read_only() and status.is_read_only(),
		"failure telemetry and nested metrics are immutable")
	var replay: Variant = owner.call(
		"_handle_raid_phase", raid, RaidAuthority.TickPhase.VISION, 2,
		_empty_raid_intents()
	)
	check(replay is bool and not bool(replay)
		and int(owner.telemetry_snapshot()["ticks_received"]) == 1,
		"quarantined owner cannot advance again")
	check(owner.teardown(generation),
		"quarantined owner permits explicit teardown before replacement")
	check(raid.teardown(raid.generation()), "failed raid tears down")
	owner.free()


func _new_raid(
	seed: int,
	suffix: String,
	use_failure_fixture: bool = false
) -> RaidAuthority:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", suffix]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(
		raid_id, &"vision_profile", &"player"
	)
	var raid: RaidAuthority = FailureFixtureAuthority.new() \
		if use_failure_fixture else RaidAuthority.new()
	if not admission.is_usable() or not raid.configure(raid_id, admission, seed):
		check(false, "fixture %s creates admitted RaidAuthority" % suffix)
		return null
	return raid


func _new_bound_fixture(
	world_id: int,
	suffix: String,
	provided_owner: RaidVisionWorldOwner = null,
	use_failure_fixture: bool = false
) -> Dictionary:
	var raid := _new_raid(world_id, suffix, use_failure_fixture)
	if raid == null:
		return {}
	var owner: RaidVisionWorldOwner = provided_owner \
		if provided_owner != null else VisionOwner.new()
	if owner.get_parent() == null:
		root.add_child(owner)
	if not owner.configure(world_id):
		check(false, "fixture %s configures Vision owner: %s" % [
			suffix, owner.last_error,
		])
		return {}
	if not owner.register_with_raid_authority(raid):
		check(false, "fixture %s binds Vision slot: %s" % [
			suffix, owner.last_error,
		])
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
	owner.free()


func _new_native_world(world_id: int) -> CommonVisionWorld2D:
	var world := CommonVisionWorld2D.new()
	var status := world.configure(
		world_id,
		Config.OFFLINE_AUTHORITY_ROLE,
		Config.SPATIAL_CELL_SIZE_RAW,
		Config.MAX_VISITED_CELLS,
	)
	if not _native_ok(status):
		world.free()
		return null
	return world


func _populate_native_budget_fixture(world: CommonVisionWorld2D) -> bool:
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
		return false
	if not _native_ok(world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_SCAV, 100, Vector2i.ZERO, Vector2i(1_000_000, 0)
	))):
		return false
	if not _native_ok(world.register_observer(_native_observer_definition(
		Config.OBSERVER_PROFILE_MUTANT, 200, Vector2i(100_000_000, 0),
		Vector2i(1_000_000, 0)
	))):
		return false
	for index in 43:
		var position := Vector2i(
			1_000_000 + (index % 10) * 100_000,
			(index / 10) * 100_000,
		)
		if not _native_ok(world.register_target(_native_target_definition(
			Config.TARGET_PROFILE_PLAYER, 1_000 + index, position
		))):
			return false
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


func _native_target_definition(
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


func _contains_native_object(
	value: Variant,
	visited: Dictionary,
	depth: int
) -> bool:
	if value is CommonVisionWorld2D:
		return true
	if depth > 12:
		return false
	if value is Callable:
		var callable := value as Callable
		if callable.get_object() is CommonVisionWorld2D:
			return true
		for argument in callable.get_bound_arguments():
			if _contains_native_object(argument, visited, depth + 1):
				return true
		return _contains_native_object(callable.get_object(), visited, depth + 1) \
			if callable.get_object() != null else false
	if value is WeakRef:
		return _contains_native_object(
			(value as WeakRef).get_ref(), visited, depth + 1
		)
	if value is Dictionary:
		for key in value as Dictionary:
			if _contains_native_object(
				(value as Dictionary)[key], visited, depth + 1
			):
				return true
		return false
	if value is Array:
		for child in value as Array:
			if _contains_native_object(child, visited, depth + 1):
				return true
		return false
	if not value is Object or not is_instance_valid(value):
		return false
	var object := value as Object
	var instance_id := object.get_instance_id()
	if visited.has(instance_id):
		return false
	visited[instance_id] = true
	for property_value in object.get_property_list():
		var property := property_value as Dictionary
		var inspected_usage := PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE
		if int(property.get("usage", 0)) & inspected_usage == 0:
			continue
		var property_name := StringName(property.get("name", &""))
		if property_name.is_empty():
			continue
		if _contains_native_object(
			object.get(property_name), visited, depth + 1
		):
			return true
	return false


func _common_vision_entry(document: Dictionary) -> Dictionary:
	for entry_value in document.get("addons", []) as Array:
		if entry_value is Dictionary \
				and String((entry_value as Dictionary).get("id", "")) \
					== Config.ADDON_ID:
			return entry_value as Dictionary
	return {}


func _method_names(object: Object) -> PackedStringArray:
	var result := PackedStringArray()
	var methods: Array = object.get_method_list()
	if object.get_script() is Script:
		methods = (object.get_script() as Script).get_script_method_list()
	for method_value in methods:
		var method := method_value as Dictionary
		result.append(String(method.get("name", "")))
	return result


func _method_argument_count(object: Object, method_name: StringName) -> int:
	for method_value in object.get_method_list():
		var method := method_value as Dictionary
		if StringName(method.get("name", &"")) == method_name:
			return (method.get("args", []) as Array).size()
	return -1


func _method_argument_class(
	object: Object,
	method_name: StringName,
	argument_index: int
) -> StringName:
	for method_value in object.get_method_list():
		var method := method_value as Dictionary
		if StringName(method.get("name", &"")) != method_name:
			continue
		var arguments := method.get("args", []) as Array
		if argument_index < 0 or argument_index >= arguments.size():
			return &""
		return StringName((arguments[argument_index] as Dictionary).get(
			"class_name", &""
		))
	return &""


func _forged_vision_handler(
	raid: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent],
	owner: RaidVisionWorldOwner
) -> bool:
	var result: Variant = owner.call("_handle_raid_phase", raid, phase, tick, intents)
	forged_callback_results.append(result is bool and bool(result))
	return true


func _attempt_later_phase_teardown(
	_raid: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	if tick == 1 and later_teardown_owner != null:
		later_teardown_result = later_teardown_owner.teardown(
			later_teardown_generation
		)
		later_teardown_error = later_teardown_owner.last_error
	return true


func _free_owner_in_later_phase(
	_raid: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	if tick == 1 and later_free_owner != null:
		later_free_owner.free()
	return true


func _noop_phase_handler(
	_raid: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	return true


func _empty_raid_intents() -> Array[ZRaidIntent]:
	var result: Array[ZRaidIntent] = []
	return result


func _native_failure_metrics_are_present(status: Dictionary) -> bool:
	for key in ["requested", "consumed", "completed", "invalidated", "deferred"]:
		if not status.has(key) or typeof(status[key]) != TYPE_INT \
				or int(status[key]) < 0:
			return false
	return true


func _native_ok(status: Dictionary) -> bool:
	return bool(status.get("ok", false))


func _point(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}


func _record_for(projection: Dictionary, target_id: int) -> Dictionary:
	for record_value in projection.get("records", []) as Array:
		if record_value is Dictionary \
				and int((record_value as Dictionary).get("target_id", 0)) == target_id:
			return record_value as Dictionary
	return {}
