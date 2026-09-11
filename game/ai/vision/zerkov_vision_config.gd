class_name ZerkovVisionConfig
extends RefCounted
## Sealed first-playable Common Vision configuration.
##
## This file is the product-owned boundary for Vision units, masks, observer
## parameters, target samples, deterministic cadence, and work limits.  The
## native addon remains the visibility authority; callers may only start a
## RaidVisionWorldOwner when this complete record matches SEALED_FINGERPRINT.

const CONFIG_SCHEMA_VERSION: int = 1
const CONFIG_ID: String = "zerkov.vision.authority.first_playable_v1"
const SEALED_FINGERPRINT: String = \
	"9a1bf1980b873fd71bcc864dc9e4f5fc32325597ed49e419e14f9167c0122ed2"

const ADDON_ID: String = "common_vision"
const ADDON_DESTINATION: String = "addons/common_vision"
const ADDON_LOCK_PATH: String = "res://config/addons.lock.json"
const RELEASE_MANIFEST_PATH: String = \
	"res://addons/common_vision/release_manifest.json"
const EXPECTED_API_VERSION: String = "0.1.0"
const EXPECTED_PROTOCOL_VERSION: int = 1
const EXPECTED_ALGORITHM_CONTRACT: int = 1
const EXPECTED_COORDINATE_SCALE: int = 1_000_000
const EXPECTED_PACKAGE_TREE_SHA256: String = \
	"868119892c8d4ce16c9329f1f22129663c035bb59d6d11005bb351969ac63c10"
const EXPECTED_RELEASE_SOURCE_REVISION: String = \
	"1d42579ac9899953a5a7b7f50f846a71706eae1d"
const EXPECTED_RELEASE_MANIFEST_SHA256: String = \
	"549ef93e061c5d39653e057bc9685c6117496a13a1d755f87584a08f1a3b0c34"
const EXPECTED_DEBUG_ARTIFACT_PATH: String = \
	"bin/libcommon_vision.macos.template_debug.universal.dylib"
const EXPECTED_DEBUG_ARTIFACT_SHA256: String = \
	"e03cc5322eff09e287dedf983262ebebc1e4bb9ad956a47a1ba06becbdf30791"
const EXPECTED_RELEASE_ARTIFACT_PATH: String = \
	"bin/libcommon_vision.macos.template_release.universal.dylib"
const EXPECTED_RELEASE_ARTIFACT_SHA256: String = \
	"a4b30328059c8329c68ab6e92a36ffdb208fa347b6094e68f6e15fd6c4dc4a55"

# Public feature values documented by Common Vision API 0.1.0.  Snapshot/delta
# and dedicated-server features are deliberately not required by this offline
# configuration slice.
const FEATURE_FIXED_POINT_LOS: int = 1
const FEATURE_VISIBILITY_MEMORY: int = 2
const FEATURE_BUDGET_SCHEDULER: int = 4
const REQUIRED_FEATURES: int = \
	FEATURE_FIXED_POINT_LOS | FEATURE_VISIBILITY_MEMORY | FEATURE_BUDGET_SCHEDULER

# Documented Common Vision hard limits, repeated here only so the game-owned
# authoring validator can fail before constructing native state.
const NATIVE_MAX_VISITED_CELLS: int = 65_536
const NATIVE_MAX_WORK_UNITS: int = 10_000_000
const NATIVE_MAX_SAMPLES: int = 8
const NATIVE_MAX_COORDINATE_RAW: int = 4_000_000_000_000
const UINT32_MAX: int = 4_294_967_295
const INT32_MIN: int = -2_147_483_648
const INT32_MAX: int = 2_147_483_647

const WORLD_ID_MAX: int = INT32_MAX
const OFFLINE_AUTHORITY_ROLE: int = 0

# Four-tile cells keep the largest authored 18-tile sight square below 128
# broadphase cells even at an adverse cell boundary.  The 256-cell limit leaves
# deterministic headroom while remaining 256x below the addon hard maximum.
const SPATIAL_CELL_SIZE_RAW: int = 4 * EXPECTED_COORDINATE_SCALE
const MAX_VISITED_CELLS: int = 256

# RaidAuthority runs at 60 Hz.  Vision evaluates on ticks 1, 4, 7, ... (20 Hz),
# so first contact is evaluated on the first authority tick without consulting
# render delta.  16,384 work units is a strict per-evaluation/per-authority-tick
# ceiling and only 0 work units are requested on the two intervening ticks.
const AUTHORITY_TICK_RATE: int = 60
const CADENCE_INTERVAL_TICKS: int = 3
const CADENCE_FIRST_TICK: int = 1
const WORK_BUDGET_PER_EVALUATION: int = 16_384

# Diagnostic history covers the latest 3.2 seconds at 20 Hz and cannot grow
# with raid duration.  Totals saturate before signed/JSON interoperability
# becomes ambiguous rather than wrapping.
const TELEMETRY_HISTORY_LIMIT: int = 64
const TELEMETRY_COUNTER_LIMIT: int = 9_007_199_254_740_000

const TARGET_LAYER_PLAYER: int = 1 << 0
const TARGET_LAYER_SCAV: int = 1 << 1
const TARGET_LAYER_MUTANT: int = 1 << 2
const TARGET_LAYER_HOSTILE: int = TARGET_LAYER_SCAV | TARGET_LAYER_MUTANT
const TARGET_LAYER_ALL_ACTORS: int = TARGET_LAYER_PLAYER | TARGET_LAYER_HOSTILE

const OCCLUDER_LAYER_STRUCTURE: int = 1 << 0
const OCCLUDER_LAYER_VEGETATION: int = 1 << 1
const OCCLUDER_LAYER_ALL: int = \
	OCCLUDER_LAYER_STRUCTURE | OCCLUDER_LAYER_VEGETATION

const OBSERVER_PROFILE_SCAV: String = "zerkov.vision.observer.scav"
const OBSERVER_PROFILE_MUTANT: String = "zerkov.vision.observer.mutant"
const TARGET_PROFILE_PLAYER: String = "zerkov.vision.target.player"
const TARGET_PROFILE_SCAV: String = "zerkov.vision.target.scav"
const TARGET_PROFILE_MUTANT: String = "zerkov.vision.target.mutant"

const SAMPLE_POLICY_ANY: int = 0
const SAMPLE_POLICY_ALL: int = 1
const CONE_COS_SCALE: int = 1_000_000
const MAX_PROFILE_RANGE_RAW: int = 18 * EXPECTED_COORDINATE_SCALE
const MAX_MEMORY_TICKS: int = 10 * AUTHORITY_TICK_RATE
const MAX_TARGET_SAMPLES: int = 3
const MAX_SAMPLE_OFFSET_RAW: int = EXPECTED_COORDINATE_SCALE / 4
const MAX_OBSERVER_PROFILES: int = 8
const MAX_TARGET_PROFILES: int = 8


static func configuration() -> Dictionary:
	return {
		"schema_version": CONFIG_SCHEMA_VERSION,
		"config_id": CONFIG_ID,
		"provenance": _expected_provenance(),
		"world": {
			"role": OFFLINE_AUTHORITY_ROLE,
			"spatial_cell_size_raw": SPATIAL_CELL_SIZE_RAW,
			"max_visited_cells": MAX_VISITED_CELLS,
		},
		"schedule": {
			"authority_tick_rate": AUTHORITY_TICK_RATE,
			"first_evaluation_tick": CADENCE_FIRST_TICK,
			"cadence_interval_ticks": CADENCE_INTERVAL_TICKS,
			"work_budget_per_evaluation": WORK_BUDGET_PER_EVALUATION,
			"telemetry_history_limit": TELEMETRY_HISTORY_LIMIT,
			"telemetry_counter_limit": TELEMETRY_COUNTER_LIMIT,
		},
		"layers": {
			"target_player": TARGET_LAYER_PLAYER,
			"target_scav": TARGET_LAYER_SCAV,
			"target_mutant": TARGET_LAYER_MUTANT,
			"occluder_structure": OCCLUDER_LAYER_STRUCTURE,
			"occluder_vegetation": OCCLUDER_LAYER_VEGETATION,
		},
		"observer_profiles": [
			_observer_profile(
				OBSERVER_PROFILE_SCAV,
				18 * EXPECTED_COORDINATE_SCALE,
				500_000, # cos(60 degrees): 120-degree total cone.
				180,     # Three seconds at the 60 Hz authority clock.
				200,
				true,
			),
			_observer_profile(
				OBSERVER_PROFILE_MUTANT,
				12 * EXPECTED_COORDINATE_SCALE,
				173_648, # cos(80 degrees): 160-degree total cone.
				120,     # Two seconds at the 60 Hz authority clock.
				100,
				false,
			),
		],
		"target_profiles": [
			_target_profile(TARGET_PROFILE_PLAYER, TARGET_LAYER_PLAYER),
			_target_profile(TARGET_PROFILE_SCAV, TARGET_LAYER_SCAV),
			_target_profile(TARGET_PROFILE_MUTANT, TARGET_LAYER_MUTANT),
		],
	}


static func fingerprint(configuration_record: Dictionary = {}) -> String:
	var candidate := configuration() if configuration_record.is_empty() \
		else configuration_record.duplicate(true)
	return ZCanonicalValue.sha256(candidate)


static func validate_configuration(
	configuration_record: Dictionary,
	require_seal: bool = true
) -> Dictionary:
	var failure := _validate_configuration_semantics(configuration_record)
	if not failure.is_empty():
		return _status(false, StringName(failure), fingerprint(configuration_record))
	var actual_fingerprint := fingerprint(configuration_record)
	if actual_fingerprint.is_empty():
		return _status(false, &"configuration_not_canonical", actual_fingerprint)
	if require_seal and actual_fingerprint != SEALED_FINGERPRINT:
		return _status(false, &"configuration_fingerprint_mismatch", actual_fingerprint)
	return _status(true, &"", actual_fingerprint)


static func observer_profile(profile_id: String) -> Dictionary:
	for entry_value in configuration()["observer_profiles"]:
		var entry := entry_value as Dictionary
		if String(entry.get("id", "")) == profile_id:
			return entry.duplicate(true)
	return {}


static func target_profile(profile_id: String) -> Dictionary:
	for entry_value in configuration()["target_profiles"]:
		var entry := entry_value as Dictionary
		if String(entry.get("id", "")) == profile_id:
			return entry.duplicate(true)
	return {}


static func is_evaluation_tick(tick: int) -> bool:
	return tick >= CADENCE_FIRST_TICK \
		and (tick - CADENCE_FIRST_TICK) % CADENCE_INTERVAL_TICKS == 0


static func validate_lock_document(
	lock_document: Dictionary,
	verify_installed_files: bool = false
) -> Dictionary:
	if int(lock_document.get("schema_version", 0)) != 1:
		return _status(false, &"addon_lock_schema_incompatible")
	var addons_value: Variant = lock_document.get("addons", null)
	if not addons_value is Array:
		return _status(false, &"addon_lock_entries_invalid")
	var matches: Array[Dictionary] = []
	for entry_value in addons_value as Array:
		if entry_value is Dictionary \
				and String((entry_value as Dictionary).get("id", "")) == ADDON_ID:
			matches.append((entry_value as Dictionary).duplicate(true))
	if matches.is_empty():
		return _status(false, &"common_vision_lock_missing")
	if matches.size() != 1:
		return _status(false, &"common_vision_lock_duplicate")
	var entry_result := _validate_locked_entry(matches[0], verify_installed_files)
	if not bool(entry_result.get("ok", false)):
		return entry_result
	return _status(
		true,
		&"",
		ZCanonicalValue.sha256(_expected_provenance()),
	)


static func runtime_preflight() -> Dictionary:
	if ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT != EXPECTED_COORDINATE_SCALE \
			or RaidClock.TICK_RATE != AUTHORITY_TICK_RATE:
		return _status(false, &"foundation_contract_incompatible")
	if not FileAccess.file_exists(ADDON_LOCK_PATH):
		return _status(false, &"addon_lock_missing")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ADDON_LOCK_PATH))
	if not parsed is Dictionary:
		return _status(false, &"addon_lock_parse_failed")
	var lock_result := validate_lock_document(parsed as Dictionary, true)
	if not bool(lock_result.get("ok", false)):
		return lock_result

	if not ClassDB.class_exists("CommonVisionVersion") \
			or not ClassDB.class_exists("CommonVisionWorld2D"):
		return _status(false, &"common_vision_native_class_missing")
	var version_probe: Object = ClassDB.instantiate("CommonVisionVersion")
	if version_probe == null:
		return _status(false, &"common_vision_version_probe_failed")
	for method_name in [
		"get_api_version",
		"get_protocol_version",
		"get_algorithm_contract_version",
		"get_coordinate_scale",
		"get_supported_features",
	]:
		if not version_probe.has_method(method_name):
			return _status(false, &"common_vision_version_method_missing")
	if String(version_probe.call("get_api_version")) != EXPECTED_API_VERSION:
		return _status(false, &"common_vision_api_incompatible")
	if int(version_probe.call("get_protocol_version")) != EXPECTED_PROTOCOL_VERSION:
		return _status(false, &"common_vision_protocol_incompatible")
	if int(version_probe.call("get_algorithm_contract_version")) \
			!= EXPECTED_ALGORITHM_CONTRACT:
		return _status(false, &"common_vision_algorithm_incompatible")
	if int(version_probe.call("get_coordinate_scale")) != EXPECTED_COORDINATE_SCALE:
		return _status(false, &"common_vision_coordinate_scale_incompatible")
	var supported_features := int(version_probe.call("get_supported_features"))
	if supported_features & REQUIRED_FEATURES != REQUIRED_FEATURES:
		return _status(false, &"common_vision_features_missing")
	var result := _status(true, &"", String(lock_result.get("fingerprint", "")))
	result["api_version"] = EXPECTED_API_VERSION
	result["protocol_version"] = EXPECTED_PROTOCOL_VERSION
	result["algorithm_contract"] = EXPECTED_ALGORITHM_CONTRACT
	result["coordinate_scale"] = EXPECTED_COORDINATE_SCALE
	result["supported_features"] = supported_features
	return result


static func _validate_configuration_semantics(configuration_record: Dictionary) -> String:
	if not _has_exact_keys(configuration_record, PackedStringArray([
		"schema_version", "config_id", "provenance", "world", "schedule",
		"layers", "observer_profiles", "target_profiles",
	])):
		return "configuration_schema_invalid"
	if int(configuration_record.get("schema_version", 0)) != CONFIG_SCHEMA_VERSION \
			or String(configuration_record.get("config_id", "")) != CONFIG_ID:
		return "configuration_identity_incompatible"
	if configuration_record.get("provenance", null) != _expected_provenance():
		return "configuration_provenance_incompatible"

	var world_value: Variant = configuration_record.get("world", null)
	if not world_value is Dictionary:
		return "world_configuration_invalid"
	var world := world_value as Dictionary
	if not _has_exact_keys(world, PackedStringArray([
		"role", "spatial_cell_size_raw", "max_visited_cells",
	])):
		return "world_configuration_invalid"
	if int(world.get("role", -1)) != OFFLINE_AUTHORITY_ROLE:
		return "world_role_invalid"
	var cell_size := int(world.get("spatial_cell_size_raw", 0))
	var visited_cells := int(world.get("max_visited_cells", 0))
	if cell_size <= 0 or cell_size > NATIVE_MAX_COORDINATE_RAW:
		return "spatial_cell_size_invalid"
	if visited_cells <= 0 or visited_cells > NATIVE_MAX_VISITED_CELLS:
		return "max_visited_cells_invalid"

	var schedule_value: Variant = configuration_record.get("schedule", null)
	if not schedule_value is Dictionary:
		return "vision_schedule_invalid"
	var schedule := schedule_value as Dictionary
	if not _has_exact_keys(schedule, PackedStringArray([
		"authority_tick_rate", "first_evaluation_tick", "cadence_interval_ticks",
		"work_budget_per_evaluation", "telemetry_history_limit",
		"telemetry_counter_limit",
	])):
		return "vision_schedule_invalid"
	var tick_rate := int(schedule.get("authority_tick_rate", 0))
	var first_tick := int(schedule.get("first_evaluation_tick", -1))
	var cadence := int(schedule.get("cadence_interval_ticks", 0))
	var work_budget := int(schedule.get("work_budget_per_evaluation", -1))
	var history_limit := int(schedule.get("telemetry_history_limit", 0))
	var counter_limit := int(schedule.get("telemetry_counter_limit", 0))
	if tick_rate <= 0 or first_tick <= 0 or cadence <= 0 \
			or cadence > tick_rate or tick_rate % cadence != 0:
		return "vision_cadence_invalid"
	if work_budget <= 0 or work_budget > NATIVE_MAX_WORK_UNITS:
		return "vision_work_budget_invalid"
	if history_limit <= 0 or history_limit > 256 \
			or counter_limit <= 0 or counter_limit > TELEMETRY_COUNTER_LIMIT:
		return "vision_telemetry_bounds_invalid"

	var layers_value: Variant = configuration_record.get("layers", null)
	if not layers_value is Dictionary:
		return "vision_layers_invalid"
	var layers := layers_value as Dictionary
	if not _has_exact_keys(layers, PackedStringArray([
		"target_player", "target_scav", "target_mutant",
		"occluder_structure", "occluder_vegetation",
	])):
		return "vision_layers_invalid"
	var target_layers := [
		int(layers.get("target_player", 0)),
		int(layers.get("target_scav", 0)),
		int(layers.get("target_mutant", 0)),
	]
	var occluder_layers := [
		int(layers.get("occluder_structure", 0)),
		int(layers.get("occluder_vegetation", 0)),
	]
	if not _layers_are_disjoint_single_bits(target_layers) \
			or not _layers_are_disjoint_single_bits(occluder_layers):
		return "vision_layers_invalid"

	var observer_profiles_value: Variant = configuration_record.get("observer_profiles", null)
	if not observer_profiles_value is Array:
		return "observer_profiles_invalid"
	var observer_profiles := observer_profiles_value as Array
	if observer_profiles.is_empty() or observer_profiles.size() > MAX_OBSERVER_PROFILES:
		return "observer_profile_count_invalid"
	var observer_ids: Dictionary = {}
	for entry_value in observer_profiles:
		if not entry_value is Dictionary:
			return "observer_profile_invalid"
		var entry := entry_value as Dictionary
		var observer_failure := _validate_observer_profile(entry, cell_size, visited_cells)
		if not observer_failure.is_empty():
			return observer_failure
		var profile_id := String(entry.get("id", ""))
		if observer_ids.has(profile_id):
			return "observer_profile_duplicate"
		observer_ids[profile_id] = true

	var target_profiles_value: Variant = configuration_record.get("target_profiles", null)
	if not target_profiles_value is Array:
		return "target_profiles_invalid"
	var target_profiles := target_profiles_value as Array
	if target_profiles.is_empty() or target_profiles.size() > MAX_TARGET_PROFILES:
		return "target_profile_count_invalid"
	var target_ids: Dictionary = {}
	for entry_value in target_profiles:
		if not entry_value is Dictionary:
			return "target_profile_invalid"
		var entry := entry_value as Dictionary
		var target_failure := _validate_target_profile(entry)
		if not target_failure.is_empty():
			return target_failure
		var profile_id := String(entry.get("id", ""))
		if target_ids.has(profile_id):
			return "target_profile_duplicate"
		target_ids[profile_id] = true
	return ""


static func _validate_observer_profile(
	profile: Dictionary,
	cell_size: int,
	visited_cell_limit: int
) -> String:
	if not _has_exact_keys(profile, PackedStringArray([
		"id", "range_raw", "cone_cos_million", "full_circle", "target_mask",
		"occluder_mask", "memory_ticks", "priority", "urgent",
	])):
		return "observer_profile_invalid"
	var profile_id := String(profile.get("id", ""))
	if not ZIdentityRules.is_valid(profile_id, &"vision"):
		return "observer_profile_id_invalid"
	var range_raw := int(profile.get("range_raw", 0))
	if range_raw <= 0 or range_raw > MAX_PROFILE_RANGE_RAW \
			or range_raw > ZWorldUnits.MAX_CANONICAL_RAW:
		return "observer_range_invalid"
	# Add two cells to cover both inclusive edges at an adverse cell boundary.
	var worst_axis_cells := (range_raw * 2 + cell_size - 1) / cell_size + 2
	if worst_axis_cells * worst_axis_cells > visited_cell_limit:
		return "observer_grid_span_invalid"
	var cone := int(profile.get("cone_cos_million", -1))
	if cone < 0 or cone > CONE_COS_SCALE:
		return "observer_cone_invalid"
	if typeof(profile.get("full_circle", null)) != TYPE_BOOL:
		return "observer_full_circle_invalid"
	if not _mask_is_valid(int(profile.get("target_mask", 0))) \
			or not _mask_is_valid(int(profile.get("occluder_mask", 0))):
		return "observer_mask_invalid"
	var memory_ticks := int(profile.get("memory_ticks", -1))
	if memory_ticks < 0 or memory_ticks > MAX_MEMORY_TICKS:
		return "observer_memory_invalid"
	var priority := int(profile.get("priority", INT32_MIN - 1))
	if priority < INT32_MIN or priority > INT32_MAX:
		return "observer_priority_invalid"
	if typeof(profile.get("urgent", null)) != TYPE_BOOL:
		return "observer_urgent_invalid"
	return ""


static func _validate_target_profile(profile: Dictionary) -> String:
	if not _has_exact_keys(profile, PackedStringArray([
		"id", "mask", "sample_policy", "sample_offsets",
	])):
		return "target_profile_invalid"
	var profile_id := String(profile.get("id", ""))
	if not ZIdentityRules.is_valid(profile_id, &"vision"):
		return "target_profile_id_invalid"
	if not _mask_is_valid(int(profile.get("mask", 0))):
		return "target_mask_invalid"
	var sample_policy := int(profile.get("sample_policy", -1))
	if sample_policy != SAMPLE_POLICY_ANY and sample_policy != SAMPLE_POLICY_ALL:
		return "target_sample_policy_invalid"
	var offsets_value: Variant = profile.get("sample_offsets", null)
	if not offsets_value is Array:
		return "target_samples_invalid"
	var offsets := offsets_value as Array
	if offsets.is_empty() or offsets.size() > MAX_TARGET_SAMPLES \
			or offsets.size() > NATIVE_MAX_SAMPLES:
		return "target_sample_count_invalid"
	var seen_offsets: Dictionary = {}
	for point_value in offsets:
		if not point_value is Dictionary:
			return "target_sample_invalid"
		var point := point_value as Dictionary
		if not _has_exact_keys(point, PackedStringArray(["x", "y"])) \
				or typeof(point.get("x", null)) != TYPE_INT \
				or typeof(point.get("y", null)) != TYPE_INT:
			return "target_sample_invalid"
		var x := int(point["x"])
		var y := int(point["y"])
		if absi(x) > MAX_SAMPLE_OFFSET_RAW or absi(y) > MAX_SAMPLE_OFFSET_RAW:
			return "target_sample_out_of_range"
		var key := "%d:%d" % [x, y]
		if seen_offsets.has(key):
			return "target_sample_duplicate"
		seen_offsets[key] = true
	return ""


static func _validate_locked_entry(entry: Dictionary, verify_files: bool) -> Dictionary:
	if String(entry.get("destination", "")) != ADDON_DESTINATION \
			or String(entry.get("version", "")) != EXPECTED_API_VERSION \
			or String(entry.get("api_version", "")) != EXPECTED_API_VERSION \
			or int(entry.get("protocol_version", 0)) != EXPECTED_PROTOCOL_VERSION:
		return _status(false, &"common_vision_lock_identity_incompatible")
	var schemas_value: Variant = entry.get("schema_versions", null)
	if not schemas_value is Dictionary \
			or int((schemas_value as Dictionary).get("algorithm_contract", 0)) \
				!= EXPECTED_ALGORITHM_CONTRACT:
		return _status(false, &"common_vision_lock_algorithm_incompatible")
	var source_value: Variant = entry.get("source", null)
	if not source_value is Dictionary:
		return _status(false, &"common_vision_lock_source_invalid")
	var source := source_value as Dictionary
	if String(source.get("release_source_revision", "")) \
			!= EXPECTED_RELEASE_SOURCE_REVISION \
			or String(source.get("package_tree_sha256", "")) \
				!= EXPECTED_PACKAGE_TREE_SHA256 \
			or String(source.get("release_manifest_sha256", "")) \
				!= EXPECTED_RELEASE_MANIFEST_SHA256:
		return _status(false, &"common_vision_lock_provenance_incompatible")

	var artifacts_value: Variant = entry.get("native_artifacts", null)
	if not artifacts_value is Array or (artifacts_value as Array).size() != 2:
		return _status(false, &"common_vision_lock_artifacts_invalid")
	var artifacts_by_path: Dictionary = {}
	for artifact_value in artifacts_value as Array:
		if not artifact_value is Dictionary:
			return _status(false, &"common_vision_lock_artifacts_invalid")
		var artifact := artifact_value as Dictionary
		var path := String(artifact.get("path", ""))
		if path.is_empty() or artifacts_by_path.has(path):
			return _status(false, &"common_vision_lock_artifact_duplicate")
		artifacts_by_path[path] = String(artifact.get("sha256", ""))
	for expected in [
		{
			"path": EXPECTED_DEBUG_ARTIFACT_PATH,
			"sha256": EXPECTED_DEBUG_ARTIFACT_SHA256,
		},
		{
			"path": EXPECTED_RELEASE_ARTIFACT_PATH,
			"sha256": EXPECTED_RELEASE_ARTIFACT_SHA256,
		},
	]:
		var path := String(expected["path"])
		var expected_sha := String(expected["sha256"])
		if String(artifacts_by_path.get(path, "")) != expected_sha:
			return _status(false, &"common_vision_lock_artifact_incompatible")
		if verify_files:
			var resource_path := "res://%s/%s" % [ADDON_DESTINATION, path]
			if not FileAccess.file_exists(resource_path) \
					or FileAccess.get_sha256(resource_path) != expected_sha:
				return _status(false, &"common_vision_artifact_hash_mismatch")
	if verify_files and (
		not FileAccess.file_exists(RELEASE_MANIFEST_PATH)
		or FileAccess.get_sha256(RELEASE_MANIFEST_PATH) \
			!= EXPECTED_RELEASE_MANIFEST_SHA256
	):
		return _status(false, &"common_vision_manifest_hash_mismatch")
	return _status(true)


static func _observer_profile(
	profile_id: String,
	range_raw: int,
	cone_cos_million: int,
	memory_ticks: int,
	priority: int,
	urgent: bool
) -> Dictionary:
	return {
		"id": profile_id,
		"range_raw": range_raw,
		"cone_cos_million": cone_cos_million,
		"full_circle": false,
		"target_mask": TARGET_LAYER_PLAYER,
		"occluder_mask": OCCLUDER_LAYER_ALL,
		"memory_ticks": memory_ticks,
		"priority": priority,
		"urgent": urgent,
	}


static func _target_profile(profile_id: String, mask: int) -> Dictionary:
	return {
		"id": profile_id,
		"mask": mask,
		"sample_policy": SAMPLE_POLICY_ANY,
		"sample_offsets": [
			{"x": 0, "y": 0},
			{"x": 0, "y": -MAX_SAMPLE_OFFSET_RAW},
			{"x": 0, "y": MAX_SAMPLE_OFFSET_RAW},
		],
	}


static func _expected_provenance() -> Dictionary:
	return {
		"addon_id": ADDON_ID,
		"api_version": EXPECTED_API_VERSION,
		"protocol_version": EXPECTED_PROTOCOL_VERSION,
		"algorithm_contract": EXPECTED_ALGORITHM_CONTRACT,
		"coordinate_scale": EXPECTED_COORDINATE_SCALE,
		"required_features": REQUIRED_FEATURES,
		"release_source_revision": EXPECTED_RELEASE_SOURCE_REVISION,
		"package_tree_sha256": EXPECTED_PACKAGE_TREE_SHA256,
		"release_manifest_sha256": EXPECTED_RELEASE_MANIFEST_SHA256,
		"artifacts": [
			{
				"path": EXPECTED_DEBUG_ARTIFACT_PATH,
				"sha256": EXPECTED_DEBUG_ARTIFACT_SHA256,
			},
			{
				"path": EXPECTED_RELEASE_ARTIFACT_PATH,
				"sha256": EXPECTED_RELEASE_ARTIFACT_SHA256,
			},
		],
	}


static func _layers_are_disjoint_single_bits(values: Array) -> bool:
	var combined: int = 0
	for value in values:
		var layer := int(value)
		if not _mask_is_valid(layer) or layer & (layer - 1) != 0 \
				or combined & layer != 0:
			return false
		combined |= layer
	return true


static func _mask_is_valid(mask: int) -> bool:
	return mask > 0 and mask <= UINT32_MAX


static func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


static func _status(
	ok: bool,
	reason: StringName = &"",
	actual_fingerprint: String = ""
) -> Dictionary:
	return {
		"ok": ok,
		"reason": reason,
		"fingerprint": actual_fingerprint,
	}
