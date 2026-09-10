extends SceneTree
## Run with:
## godot --headless --path . --script res://tests/addons/combined_addons_smoke.gd

const LOCK_PATH := "res://config/addons.lock.json"

const VERSION_PROBES := {
	"common_ui": {
		"class": "CommonUIRuntime",
		"api_method": "get_api_version",
		"protocol_method": "",
		"required_classes": ["CommonUIRuntime", "CommonInputBindingRegistry"],
	},
	"common_vision": {
		"class": "CommonVisionVersion",
		"api_method": "get_api_version",
		"protocol_method": "get_protocol_version",
		"required_classes": ["CommonVisionVersion", "CommonVisionWorld2D"],
		"extra": {"algorithm_contract": "get_algorithm_contract_version"},
	},
	"gameplay_abilities": {
		"class": "GameplayAbilityVersion",
		"api_method": "get_api_version",
		"protocol_method": "get_protocol_version",
		"required_classes": [
			"GameplayAbilityVersion",
			"GameplayAbilityComponent",
			"GameplayAbilityWorldCoordinator",
		],
		"extra": {"manifest_algorithm": "get_manifest_algorithm"},
	},
	"inventory_system": {
		"class": "InventoryCatalog",
		"api_method": "api_version",
		"protocol_method": "protocol_version",
		"required_classes": [
			"InventoryCatalog",
			"InventoryAuthority",
			"InventorySnapshotResource",
		],
		"extra": {
			"resource": "resource_schema_version",
			"manifest_algorithm": "manifest_algorithm",
		},
	},
	"level_task_system": {
		"class": "LevelTaskSystemVersion",
		"api_method": "get_api_version",
		"protocol_method": "get_protocol_version",
		"required_classes": [
			"LevelTaskSystemVersion",
			"LevelTaskRuntimeBridge",
			"LevelTaskGraphDefinition",
		],
		"extra": {
			"task_graph_definition": "get_task_graph_definition_schema_version",
			"resource": "get_resource_schema_version",
			"snapshot": "get_snapshot_schema_version",
			"canonical_format": "get_canonical_format_version",
			"manifest_algorithm": "get_manifest_algorithm",
			"catalog_fingerprint_algorithm": "get_catalog_fingerprint_algorithm",
		},
	},
	"weapon_system": {
		"class": "WeaponSystemVersion",
		"api_method": "get_api_version",
		"protocol_method": "get_protocol_version",
		"required_classes": [
			"WeaponSystemVersion",
			"WeaponDefinitionCatalog",
			"WeaponAuthority",
		],
		"extra": {
			"resource": "get_resource_schema_version",
			"manifest_algorithm": "get_manifest_algorithm",
		},
	},
}

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("ADDON_SMOKE: " + message)


func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		check(false, "missing JSON file: " + path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(parsed is Dictionary, "JSON root is an object: " + path)
	return parsed


func same_value(actual: Variant, expected: Variant) -> bool:
	if expected is int or expected is float:
		return int(actual) == int(expected)
	return str(actual) == str(expected)


func probe_object(addon_id: String, native_class: String) -> Object:
	if addon_id == "common_ui":
		return get_root().get_node_or_null("CommonUI")
	return ClassDB.instantiate(native_class)


func verify_runtime(entry: Dictionary) -> void:
	var addon_id := str(entry.get("id", ""))
	var probe_spec: Dictionary = VERSION_PROBES.get(addon_id, {})
	check(not probe_spec.is_empty(), addon_id + ": version probe is declared")
	if probe_spec.is_empty():
		return

	for required_class: String in probe_spec.get("required_classes", []):
		check(ClassDB.class_exists(required_class), addon_id + ": native class registered: " + required_class)

	var native_class := str(probe_spec.get("class", ""))
	var probe := probe_object(addon_id, native_class)
	check(probe != null, addon_id + ": can instantiate version probe " + native_class)
	if probe == null:
		return

	var api_method := str(probe_spec.get("api_method", ""))
	check(probe.has_method(api_method), addon_id + ": exposes " + api_method)
	if probe.has_method(api_method):
		var actual_api: Variant = probe.call(api_method)
		check(
			same_value(actual_api, entry.get("api_version")),
			addon_id + ": compiled API version matches lock; expected %s got %s"
				% [entry.get("api_version"), actual_api],
		)

	var protocol_method := str(probe_spec.get("protocol_method", ""))
	var expected_protocol: Variant = entry.get("protocol_version")
	if not protocol_method.is_empty() and expected_protocol != null:
		check(probe.has_method(protocol_method), addon_id + ": exposes " + protocol_method)
		if probe.has_method(protocol_method):
			var actual_protocol: Variant = probe.call(protocol_method)
			check(
				same_value(actual_protocol, expected_protocol),
				addon_id + ": compiled protocol version matches lock; expected %s got %s"
					% [expected_protocol, actual_protocol],
			)

	var schema_versions: Dictionary = entry.get("schema_versions", {})
	var extra_probes: Dictionary = probe_spec.get("extra", {})
	for schema_key: String in extra_probes:
		var method_name := str(extra_probes[schema_key])
		check(probe.has_method(method_name), addon_id + ": exposes " + method_name)
		if probe.has_method(method_name):
			var actual_value: Variant = probe.call(method_name)
			var expected_value: Variant = schema_versions.get(schema_key)
			check(
				same_value(actual_value, expected_value),
				addon_id + ": compiled %s matches lock; expected %s got %s"
					% [schema_key, expected_value, actual_value],
			)


func verify_package(entry: Dictionary, enabled_plugins: PackedStringArray) -> void:
	var addon_id := str(entry.get("id", ""))
	var destination := str(entry.get("destination", ""))
	var package_root := "res://" + destination
	var plugin_path := package_root + "/plugin.cfg"
	check(FileAccess.file_exists(plugin_path), addon_id + ": plugin.cfg exists")
	if bool(entry.get("integration", {}).get("editor_plugin_enabled", false)):
		check(enabled_plugins.has(plugin_path), addon_id + ": documented editor plugin enabled")

	var packaged_manifest_path := package_root + "/release_manifest.json"
	var packaged_manifest: Variant = read_json(packaged_manifest_path)
	if packaged_manifest is Dictionary:
		check(packaged_manifest.get("addon") == addon_id, addon_id + ": release manifest identity matches")
		check(packaged_manifest.get("version") == entry.get("version"), addon_id + ": package version matches lock")
		check(packaged_manifest.get("api_version") == entry.get("api_version"), addon_id + ": package API version matches lock")
		check(packaged_manifest.get("protocol_version") == entry.get("protocol_version"), addon_id + ": package protocol version matches lock")
		check(
			FileAccess.get_sha256(packaged_manifest_path) == str(entry.get("source", {}).get("release_manifest_sha256", "")),
			addon_id + ": packaged release manifest hash matches lock",
		)

	for artifact: Dictionary in entry.get("native_artifacts", []):
		var artifact_path := package_root + "/" + str(artifact.get("path", ""))
		check(FileAccess.file_exists(artifact_path), addon_id + ": native artifact exists: " + artifact_path)
		if FileAccess.file_exists(artifact_path):
			check(
				FileAccess.get_sha256(artifact_path) == str(artifact.get("sha256", "")),
				addon_id + ": native artifact hash matches lock: " + artifact_path,
			)

	verify_runtime(entry)


func run() -> void:
	var engine_version := Engine.get_version_info()
	check(int(engine_version.get("major", 0)) == 4, "Godot major version is 4")
	check(int(engine_version.get("minor", 0)) >= 7, "Godot version satisfies the 4.7 minimum")

	var lock: Variant = read_json(LOCK_PATH)
	if not lock is Dictionary:
		print("ADDON_SMOKE_RESULT checks=", checks, " failures=", failures)
		quit(1)
		return
	check(int(lock.get("schema_version", 0)) == 1, "lock schema version is supported")
	var addon_entries: Array = lock.get("addons", [])
	check(addon_entries.size() == VERSION_PROBES.size(), "lock contains all six add-ons")

	var enabled_plugins: PackedStringArray = ProjectSettings.get_setting(
		"editor_plugins/enabled", PackedStringArray()
	)
	for entry: Dictionary in addon_entries:
		verify_package(entry, enabled_plugins)

	check(get_root().get_node_or_null("CommonUI") is CommonUIRuntime, "CommonUI is the native runtime autoload")
	for forbidden_autoload: String in [
		"CommonVision",
		"GameplayAbilities",
		"InventorySystem",
		"LevelTaskSystem",
		"WeaponSystem",
	]:
		check(
			not ProjectSettings.has_setting("autoload/" + forbidden_autoload),
			forbidden_autoload + " does not install process-global authority",
		)

	print("ADDON_SMOKE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
