class_name ZerkovAssetRegistry
extends RefCounted
## Typed, read-only access to the game-owned curated asset manifest.
##
## The JSON file is the source of truth.  This loader never derives an alias,
## frame, crop, import setting, or content identity from a filename.  Callers
## receive deep copies so presentation code cannot mutate the registry.

const MANIFEST_PATH: String = "res://game/content/asset_registry.json"
const SCHEMA_VERSION: int = 1
const REGISTRY_ID: String = "zerkov.assets"
const ASSET_ID_PREFIX: String = "zerkov.asset."

const AVAILABILITY_IMPORTED: String = "imported"
const AVAILABILITY_IMPORTED_SOURCE_MISSING: String = "imported_source_missing"
const AVAILABILITY_PENDING_UNIMPORTED: String = "pending_unimported"

const SOURCE_STATUS_AVAILABLE: String = "available"
const SOURCE_STATUS_AVAILABLE_EXTERNAL: String = "available_external"
const SOURCE_STATUS_MISSING: String = "missing"
const SOURCE_STATUS_UNAVAILABLE_EXTERNAL: String = "unavailable_external"

const LICENSE_CLEARED: String = "cleared"
const LICENSE_BLOCKED: String = "blocked"
const LICENSE_UNKNOWN: String = "unknown"

const _EXPECTED_DISTRIBUTION_BLOCKERS: PackedStringArray = [
	"inventory_system",
	"weapon_system",
	"zerkov-handoff-and-original-art",
]
const _PIXEL_KINDS: PackedStringArray = [
	"sprite",
	"icon",
	"tile",
	"atlas",
	"sheet",
	"font",
	"prop_sheet",
]
const _KNOWN_CONTENT_LINK_TARGETS: PackedStringArray = [
	"zerkov.item.weapon.akm",
	"zerkov.item.weapon.machete",
	"zerkov.item.ammo.caliber_762x39_standard",
	"zerkov.item.magazine.akm_30",
	"zerkov.item.medical.bandage",
	"zerkov.item.medical.splint",
	"zerkov.item.quest.supply_crate",
	"zerkov.item.quest.sealed_documents",
	"zerkov.item.valuable.encrypted_drive",
	"zerkov.item.valuable.gold_watch",
	"zerkov.item.junk.battery",
	"zerkov.item.junk.duct_tape",
	"zerkov.item.junk.bolts",
	"zerkov.item.junk.scrap_metal",
	"zerkov.item.gear.rig_basic",
	"zerkov.item.gear.backpack_daypack",
	"zerkov.weapon.akm",
	"zerkov.weapon.machete",
]

var _manifest: Dictionary = {}
var _entries_by_id: Dictionary = {}
var _entries_by_alias: Dictionary = {}
var _fingerprint: String = ""
var _findings: Array[Dictionary] = []
var _loaded := false


## Build the default registry from the checked-in JSON manifest.
static func build() -> ZerkovAssetRegistry:
	return ZerkovAssetRegistry.new()


## Descriptive aliases used by content factories and tests.
static func build_registry() -> ZerkovAssetRegistry:
	return build()


static func load_default() -> ZerkovAssetRegistry:
	return build()


## Convenience preflight for callers that only need validation findings.
static func validate_default() -> Array[Dictionary]:
	return build().validation_findings()


## Validate a detached candidate manifest without changing the default registry.
static func validate_candidate(candidate: Variant) -> Array[Dictionary]:
	var validator := ZerkovAssetRegistry.new()
	if not candidate is Dictionary:
		return [
			validator._finding(
				"error",
				"manifest_type",
				"Manifest candidate must be a JSON object",
			)
		]
	return validator._validate_manifest(candidate as Dictionary)


func _init() -> void:
	_load_manifest()


func is_loaded() -> bool:
	return _loaded


func is_valid() -> bool:
	return _loaded and validation_errors().is_empty()


## The SHA-256 of the exact checked-in manifest bytes.
func manifest_fingerprint() -> String:
	return _fingerprint


func fingerprint() -> String:
	return manifest_fingerprint()


func manifest() -> Dictionary:
	return _manifest.duplicate(true)


func entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var values: Variant = _manifest.get("assets", [])
	if not values is Array:
		return result
	for value in values:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	return result


## Exact ID lookup.  Unknown IDs return an empty dictionary.
func get_asset(asset_id: Variant) -> Dictionary:
	var key := _string_value(asset_id)
	var value: Variant = _entries_by_id.get(key, null)
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


## Exact alias lookup; no case folding, basename matching, or filename guessing.
func resolve_alias(alias: Variant) -> Dictionary:
	var key := _string_value(alias)
	var value: Variant = _entries_by_alias.get(key, null)
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


func distribution_blockers() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var values: Variant = _manifest.get("distribution_blockers", [])
	if not values is Array:
		return result
	for value in values:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	return result


func validation_findings() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for finding in _findings:
		result.append(finding.duplicate(true))
	return result


func validate() -> Array[Dictionary]:
	return validation_findings()


func validation_errors() -> Array[Dictionary]:
	return _findings_with_severity("error")


func validation_warnings() -> Array[Dictionary]:
	return _findings_with_severity("warning")


func _findings_with_severity(severity: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for finding in _findings:
		if String(finding.get("severity", "")) == severity:
			result.append(finding.duplicate(true))
	return result


func _load_manifest() -> void:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		_findings.append(_finding(
			"error",
			"manifest_unreadable",
			"Could not open " + MANIFEST_PATH,
		))
		return
	var bytes := file.get_buffer(file.get_length())
	file.close()
	_fingerprint = _sha256_bytes(bytes)
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		_findings.append(_finding(
			"error",
			"manifest_invalid_json",
			"Manifest must contain a JSON object: " + MANIFEST_PATH,
		))
		return
	_manifest = _normalize_json_numbers((parsed as Dictionary).duplicate(true)) as Dictionary
	_index_entries()
	_findings = _validate_manifest(_manifest)
	_loaded = true


func _index_entries() -> void:
	_entries_by_id.clear()
	_entries_by_alias.clear()
	var values: Variant = _manifest.get("assets", [])
	if not values is Array:
		return
	for value in values:
		if not value is Dictionary:
			continue
		var entry := value as Dictionary
		var asset_id := _string_value(entry.get("id", ""))
		if not asset_id.is_empty() and not _entries_by_id.has(asset_id):
			_entries_by_id[asset_id] = entry
		var aliases: Variant = entry.get("aliases", [])
		if aliases is Array:
			for alias_value in aliases:
				var alias := _string_value(alias_value)
				if not alias.is_empty() and not _entries_by_alias.has(alias):
					_entries_by_alias[alias] = entry


func _validate_manifest(manifest: Dictionary) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if not manifest.has("schema_version") or not _is_manifest_integer(manifest.get("schema_version")):
		findings.append(_finding(
			"error",
			"schema_version_type",
			"Schema version must be a JSON integer",
		))
	elif int(manifest.get("schema_version")) != SCHEMA_VERSION:
		findings.append(_finding(
			"error",
			"schema_version",
			"Expected schema version " + str(SCHEMA_VERSION),
		))
	if not manifest.has("registry_id") or typeof(manifest.get("registry_id")) != TYPE_STRING:
		findings.append(_finding(
			"error",
			"registry_id_type",
			"Registry id must be a JSON string",
		))
	elif manifest.get("registry_id") != REGISTRY_ID:
		findings.append(_finding(
			"error",
			"registry_id",
			"Expected registry id " + REGISTRY_ID,
		))
	if not manifest.has("content_version") or not _is_manifest_positive_int(manifest.get("content_version")):
		findings.append(_finding(
			"error",
			"content_version",
			"Content version must be a positive integer",
		))
	if not manifest.has("source_manifest") or typeof(manifest.get("source_manifest")) != TYPE_STRING:
		findings.append(_finding(
			"error",
			"source_manifest_type",
			"Source manifest must be a project-relative path string",
		))
	elif (
		not _is_strict_relative_path(String(manifest.get("source_manifest")))
		or not FileAccess.file_exists("res://" + String(manifest.get("source_manifest")))
	):
		findings.append(_finding(
			"error",
			"source_manifest",
			"Source manifest must reference an existing project-relative file",
		))

	var forbidden_value: Variant = manifest.get("forbidden_paths", [])
	var forbidden_paths: Array = []
	if not forbidden_value is Array or (forbidden_value as Array).is_empty():
		findings.append(_finding(
			"error",
			"forbidden_paths",
			"Manifest must declare forbidden source-path markers",
		))
	else:
		for marker_value in forbidden_value:
			if typeof(marker_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"forbidden_path_type",
					"Forbidden path markers must be strings",
				))
				continue
			var marker := String(marker_value)
			if marker.is_empty() or marker.strip_edges().is_empty():
				findings.append(_finding(
					"error",
					"forbidden_path_empty",
					"Forbidden path markers cannot be empty",
				))
			else:
				forbidden_paths.append(marker)

	var blocker_value: Variant = manifest.get("distribution_blockers", [])
	var blocker_ids: Dictionary = {}
	if not blocker_value is Array:
		findings.append(_finding(
			"error",
			"distribution_blockers",
			"Manifest must expose the current distribution blockers",
		))
	else:
		for blocker_entry_value in blocker_value:
			if not blocker_entry_value is Dictionary:
				findings.append(_finding(
					"error",
					"distribution_blocker_shape",
					"Distribution blocker must be an object",
				))
				continue
			var blocker := blocker_entry_value as Dictionary
			var blocker_id_value: Variant = blocker.get("id", null)
			var blocker_status_value: Variant = blocker.get("status", null)
			var blocker_reference_value: Variant = blocker.get("reference", null)
			var blocker_reason_value: Variant = blocker.get("reason", null)
			if typeof(blocker_id_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"distribution_blocker_id_type",
					"Distribution blocker id must be a string",
				))
			if typeof(blocker_status_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"distribution_blocker_status_type",
					"Distribution blocker status must be a string",
				))
			if typeof(blocker_reference_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"distribution_blocker_reference_type",
					"Distribution blocker reference must be a string",
				))
			if typeof(blocker_reason_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"distribution_blocker_reason_type",
					"Distribution blocker reason must be a string",
				))
			var blocker_id := String(blocker_id_value) if typeof(blocker_id_value) == TYPE_STRING else ""
			if blocker_id.is_empty() or blocker_ids.has(blocker_id):
				findings.append(_finding(
					"error",
					"distribution_blocker_id",
					"Distribution blocker ids must be non-empty and unique",
				))
			else:
				blocker_ids[blocker_id] = true
			if String(blocker_status_value) != LICENSE_BLOCKED:
				findings.append(_finding(
					"error",
					"distribution_blocker_status",
					"Distribution blocker must remain blocked: " + blocker_id,
				))
			if String(blocker_reference_value).is_empty():
				findings.append(_finding(
					"error",
					"distribution_blocker_reference",
					"Distribution blocker needs a canonical reference: " + blocker_id,
				))
			if String(blocker_reason_value).is_empty():
				findings.append(_finding(
					"error",
					"distribution_blocker_reason",
					"Distribution blocker needs an actionable reason: " + blocker_id,
				))
			elif typeof(blocker_reference_value) == TYPE_STRING:
				findings.append_array(_validate_license_reference(
					String(blocker_reference_value),
					blocker_id,
				))
	for expected_id in _EXPECTED_DISTRIBUTION_BLOCKERS:
		if not blocker_ids.has(String(expected_id)):
			findings.append(_finding(
				"error",
				"distribution_blocker_missing",
				"Expected distribution blocker is not surfaced: " + String(expected_id),
			))

	var assets_value: Variant = manifest.get("assets", null)
	if not assets_value is Array or (assets_value as Array).is_empty():
		findings.append(_finding(
			"error",
			"assets",
			"Manifest must contain at least one asset entry",
		))
		return findings

	var asset_ids: Dictionary = {}
	var aliases: Dictionary = {}
	var aliases_casefolded: Dictionary = {}
	for entry_value in assets_value:
		if not entry_value is Dictionary:
			findings.append(_finding(
				"error",
				"asset_shape",
				"Every asset entry must be an object",
			))
			continue
		var entry := entry_value as Dictionary
		if not entry.has("id") or typeof(entry.get("id")) != TYPE_STRING:
			findings.append(_finding(
				"error",
				"asset_id_type",
				"Asset id must be a JSON string",
			))
		var asset_id := String(entry.get("id")) if typeof(entry.get("id")) == TYPE_STRING else ""
		if not _is_asset_id(asset_id):
			findings.append(_finding(
				"error",
				"asset_id",
				"Asset id must use the lower-case " + ASSET_ID_PREFIX + " namespace: " + asset_id,
				asset_id,
			))
		elif asset_ids.has(asset_id):
			findings.append(_finding(
				"error",
				"asset_id_duplicate",
				"Asset id is duplicated: " + asset_id,
				asset_id,
			))
		else:
			asset_ids[asset_id] = true

		var aliases_value: Variant = entry.get("aliases", null)
		if not aliases_value is Array or (aliases_value as Array).is_empty():
			findings.append(_finding(
				"error",
				"aliases",
				"Asset needs at least one exact runtime alias",
				asset_id,
			))
		else:
			for alias_value in aliases_value:
				if typeof(alias_value) != TYPE_STRING:
					findings.append(_finding(
						"error",
						"alias_type",
						"Runtime aliases must be JSON strings",
						asset_id,
					))
					continue
				var alias := String(alias_value)
				if not _is_alias(alias):
					findings.append(_finding(
						"error",
						"alias_shape",
						"Runtime alias has unsupported characters: " + alias,
						asset_id,
					))
				elif aliases.has(alias):
					findings.append(_finding(
						"error",
						"alias_duplicate",
						"Runtime alias is duplicated: " + alias,
						asset_id,
					))
				else:
					aliases[alias] = asset_id
				var folded_alias := alias.to_lower()
				if aliases_casefolded.has(folded_alias):
					findings.append(_finding(
						"error",
						"alias_case_collision",
						"Runtime aliases collide case-insensitively: " + alias,
						asset_id,
					))
				else:
					aliases_casefolded[folded_alias] = asset_id

		if not entry.has("availability") or typeof(entry.get("availability")) != TYPE_STRING:
			findings.append(_finding(
				"error",
				"availability_type",
				"Asset availability must be a JSON string",
				asset_id,
			))
		var availability := String(entry.get("availability")) if typeof(entry.get("availability")) == TYPE_STRING else ""
		if availability != AVAILABILITY_IMPORTED and availability != AVAILABILITY_IMPORTED_SOURCE_MISSING and availability != AVAILABILITY_PENDING_UNIMPORTED:
			findings.append(_finding(
				"error",
				"availability",
				"Unsupported asset availability: " + availability,
				asset_id,
			))

		var runtime_path_value: Variant = entry.get("runtime_path", null)
		var runtime_hash_value: Variant = entry.get("runtime_sha256", null)
		if typeof(runtime_path_value) != TYPE_STRING:
			findings.append(_finding(
				"error",
					"runtime_path_type",
					"Runtime path must be a JSON string",
					asset_id,
				))
		var runtime_path := String(runtime_path_value) if typeof(runtime_path_value) == TYPE_STRING else ""
		var runtime_hash := String(runtime_hash_value) if typeof(runtime_hash_value) == TYPE_STRING else ""
		if availability == AVAILABILITY_PENDING_UNIMPORTED:
			if not runtime_path.is_empty() or runtime_hash_value != null:
				findings.append(_finding(
					"error",
					"pending_runtime",
					"Pending assets require an empty runtime path and null runtime hash",
					asset_id,
				))
			findings.append(_finding(
				"warning",
				"pending_unimported",
				"Approved-slice source is explicit but not imported yet",
				asset_id,
			))
		else:
			if not _is_confined_runtime_path(runtime_path) or _contains_forbidden(runtime_path, forbidden_paths):
				findings.append(_finding(
					"error",
					"runtime_path",
					"Runtime path must be confined to res://assets and avoid forbidden markers",
					asset_id,
				))
			if typeof(runtime_hash_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"runtime_hash_type",
					"Imported asset runtime hash must be a JSON string",
					asset_id,
				))
			if not _is_sha256(runtime_hash):
				findings.append(_finding(
					"error",
					"runtime_hash",
					"Imported asset must carry a SHA-256 runtime hash",
					asset_id,
				))
			elif not FileAccess.file_exists(runtime_path):
				findings.append(_finding(
					"error",
					"runtime_missing",
					"Manifest runtime path does not exist: " + runtime_path,
					asset_id,
				))
			else:
				var actual_hash := _sha256_file(runtime_path)
				if actual_hash != runtime_hash:
					findings.append(_finding(
						"error",
						"runtime_hash_mismatch",
						"Runtime SHA-256 does not match " + runtime_path,
						asset_id,
					))

		var provenance_value: Variant = entry.get("provenance", null)
		if not provenance_value is Dictionary:
			findings.append(_finding(
				"error",
				"provenance_shape",
				"Asset needs an explicit provenance object",
				asset_id,
			))
		else:
			var provenance := provenance_value as Dictionary
			var source_root_value: Variant = provenance.get("source_root", null)
			var source_relative_path_value: Variant = provenance.get(
				"source_relative_path",
				null,
			)
			var source_status_value: Variant = provenance.get("source_status", null)
			var source_hash_value: Variant = provenance.get("source_sha256", null)
			if typeof(source_root_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"source_root_type",
					"Source root must be a JSON string",
					asset_id,
				))
			if typeof(source_relative_path_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"source_relative_path_type",
					"Source-relative path must be a JSON string",
					asset_id,
				))
			if typeof(source_status_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"source_status_type",
					"Source status must be a JSON string",
					asset_id,
				))
			if source_hash_value != null and typeof(source_hash_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"source_hash_type",
					"Source SHA-256 must be null or a JSON string",
					asset_id,
				))
			var source_root := String(source_root_value) if typeof(source_root_value) == TYPE_STRING else ""
			var source_relative_path := String(source_relative_path_value) if typeof(source_relative_path_value) == TYPE_STRING else ""
			var source_status := String(source_status_value) if typeof(source_status_value) == TYPE_STRING else ""
			var source_hash := String(source_hash_value) if typeof(source_hash_value) == TYPE_STRING else ""
			var source_hash_is_null := source_hash_value == null
			if not _is_source_root(source_root):
				findings.append(_finding(
					"error",
					"source_root",
					"Source root must be a canonical absolute path or HTTPS URI",
					asset_id,
				))
			if not _is_strict_relative_path(source_relative_path):
				findings.append(_finding(
					"error",
					"provenance_path",
					"Source-relative path must be strict, relative, and platform-neutral",
					asset_id,
				))
			if _contains_forbidden(source_root + "/" + source_relative_path, forbidden_paths):
				findings.append(_finding(
					"error",
					"provenance_forbidden",
					"Source provenance points at a forbidden path",
					asset_id,
				))
			if not source_status in [
				SOURCE_STATUS_AVAILABLE,
				SOURCE_STATUS_AVAILABLE_EXTERNAL,
				SOURCE_STATUS_MISSING,
				SOURCE_STATUS_UNAVAILABLE_EXTERNAL,
			]:
				findings.append(_finding(
					"error",
					"source_status",
					"Unsupported source status: " + source_status,
					asset_id,
				))
			if not source_hash_is_null and not _is_sha256(source_hash):
				findings.append(_finding(
					"error",
					"source_hash",
					"Source SHA-256 must be null or a 64-character lowercase hex digest",
					asset_id,
				))
			if (
				source_status in [SOURCE_STATUS_AVAILABLE, SOURCE_STATUS_AVAILABLE_EXTERNAL]
				and source_hash_is_null
			):
				findings.append(_finding(
					"error",
					"source_hash_missing",
					"Available source must carry a verifiable SHA-256 digest",
					asset_id,
				))
			if (
				source_status in [SOURCE_STATUS_MISSING, SOURCE_STATUS_UNAVAILABLE_EXTERNAL]
				and not source_hash_is_null
			):
				findings.append(_finding(
					"error",
					"source_hash_unverifiable",
					"Unavailable source must use a null source SHA-256",
					asset_id,
				))
			if availability == AVAILABILITY_IMPORTED and source_status != SOURCE_STATUS_AVAILABLE:
				findings.append(_finding(
					"error",
					"source_status",
					"Imported asset source must be locally available",
					asset_id,
				))
			if availability == AVAILABILITY_IMPORTED_SOURCE_MISSING:
				if source_status != SOURCE_STATUS_MISSING and source_status != SOURCE_STATUS_UNAVAILABLE_EXTERNAL:
					findings.append(_finding(
						"error",
						"source_status",
						"Source-missing asset must disclose its unavailable source",
						asset_id,
					))
				findings.append(_finding(
					"warning",
					"source_provenance_missing",
					"Runtime bytes exist but source provenance cannot be verified",
					asset_id,
				))
			if source_root.begins_with("/") and _is_strict_relative_path(source_relative_path):
				var source_file_path := _join_source_path(source_root, source_relative_path)
				var source_exists := FileAccess.file_exists(source_file_path)
				if source_status == SOURCE_STATUS_AVAILABLE:
					if not source_exists:
						findings.append(_finding(
							"error",
							"source_missing",
							"Source marked available does not exist: " + source_file_path,
							asset_id,
						))
					elif not source_hash_is_null:
						var available_hash := _sha256_file(source_file_path)
						if available_hash != source_hash:
							findings.append(_finding(
								"error",
								"source_hash_mismatch",
								"Available source SHA-256 does not match source bytes",
								asset_id,
							))
						if availability == AVAILABILITY_IMPORTED and available_hash != runtime_hash:
							findings.append(_finding(
								"error",
								"source_runtime_hash_mismatch",
								"Imported source and runtime bytes must share a digest",
								asset_id,
							))
				elif source_status == SOURCE_STATUS_AVAILABLE_EXTERNAL:
					if source_exists and not source_hash_is_null:
						var external_hash := _sha256_file(source_file_path)
						if external_hash != source_hash:
							findings.append(_finding(
								"error",
								"source_hash_mismatch",
								"External source SHA-256 does not match source bytes",
								asset_id,
							))
					elif not source_exists:
						findings.append(_finding(
							"warning",
							"source_provenance_unverifiable",
							"External source is not present for byte verification",
							asset_id,
						))
				elif source_status == SOURCE_STATUS_MISSING and source_exists:
					findings.append(_finding(
						"error",
						"source_status_mismatch",
						"Source marked missing is present: " + source_file_path,
						asset_id,
					))
				elif source_status == SOURCE_STATUS_UNAVAILABLE_EXTERNAL and source_exists:
					findings.append(_finding(
						"error",
						"source_status_mismatch",
						"Source marked unavailable is present: " + source_file_path,
						asset_id,
					))
			elif source_root.begins_with("https://"):
				if source_status != SOURCE_STATUS_UNAVAILABLE_EXTERNAL:
					findings.append(_finding(
						"error",
						"source_uri_status",
						"HTTPS source roots must be explicitly unavailable externally",
						asset_id,
					))

		if not entry.has("family") or typeof(entry.get("family")) != TYPE_STRING:
			findings.append(_finding(
				"error",
				"family_type",
				"Asset family must be a JSON string",
				asset_id,
			))
		if not entry.has("kind") or typeof(entry.get("kind")) != TYPE_STRING:
			findings.append(_finding(
				"error",
				"kind_type",
				"Asset kind must be a JSON string",
				asset_id,
			))
		var family := String(entry.get("family")) if typeof(entry.get("family")) == TYPE_STRING else ""
		var kind := String(entry.get("kind")) if typeof(entry.get("kind")) == TYPE_STRING else ""
		if family.is_empty() or kind.is_empty():
			findings.append(_finding(
				"error",
				"family_kind",
				"Asset family and kind are required",
				asset_id,
			))

		var filtering_value: Variant = entry.get("filtering", null)
		if not filtering_value is Dictionary:
			findings.append(_finding(
				"error",
				"filtering_shape",
				"Asset needs an explicit filtering policy",
				asset_id,
			))
		else:
			var filtering := filtering_value as Dictionary
			var mode_value: Variant = filtering.get("mode", null)
			if typeof(mode_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"filtering_mode_type",
					"Filtering mode must be a JSON string",
					asset_id,
				))
			var mode := String(mode_value) if typeof(mode_value) == TYPE_STRING else ""
			if mode != "nearest" and mode != "linear":
				findings.append(_finding(
					"error",
					"filtering_mode",
					"Filtering mode must be nearest or linear",
					asset_id,
				))
			if not filtering.has("mipmaps") or typeof(filtering.get("mipmaps")) != TYPE_BOOL:
				findings.append(_finding(
					"error",
					"mipmap_policy",
					"Filtering policy must explicitly declare mipmaps",
					asset_id,
				))
			if _PIXEL_KINDS.has(kind) and mode != "nearest":
				findings.append(_finding(
					"error",
					"pixel_filtering",
					"Pixel sprite/sheet/font kinds must use nearest filtering",
					asset_id,
				))

		var license_value: Variant = entry.get("license", null)
		if not license_value is Dictionary:
			findings.append(_finding(
				"error",
				"license_shape",
				"Asset needs an explicit license status/reference",
				asset_id,
			))
		else:
			var license := license_value as Dictionary
			var license_status_value: Variant = license.get("status", null)
			var license_name_value: Variant = license.get("name", null)
			var license_reference_value: Variant = license.get("reference", null)
			var license_reason_value: Variant = license.get("reason", null)
			if typeof(license_status_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"license_status_type",
					"License status must be a JSON string",
					asset_id,
				))
			if license_name_value != null and typeof(license_name_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"license_name_type",
					"License name must be null or a JSON string",
					asset_id,
				))
			if typeof(license_reference_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"license_reference_type",
					"License reference must be a JSON string",
					asset_id,
				))
			if license_reason_value != null and typeof(license_reason_value) != TYPE_STRING:
				findings.append(_finding(
					"error",
					"license_reason_type",
					"License reason must be null or a JSON string",
					asset_id,
				))
			var license_status := String(license_status_value) if typeof(license_status_value) == TYPE_STRING else ""
			var license_reference := String(license_reference_value) if typeof(license_reference_value) == TYPE_STRING else ""
			if license_status != LICENSE_CLEARED and license_status != LICENSE_BLOCKED and license_status != LICENSE_UNKNOWN:
				findings.append(_finding(
					"error",
					"license_status",
					"Unsupported asset license status",
					asset_id,
				))
			if license_reference.is_empty():
				findings.append(_finding(
					"error",
					"license_reference",
					"Asset license needs a canonical reference",
					asset_id,
				))
			elif typeof(license_reference_value) == TYPE_STRING:
				findings.append_array(_validate_license_reference(
					license_reference,
					asset_id,
				))
			if _is_unlicensed_art_family(family) and license_status == LICENSE_CLEARED:
				findings.append(_finding(
					"error",
					"art_license_clearance",
					"Uncleared art family cannot be marked cleared",
					asset_id,
				))
			if license_status == LICENSE_BLOCKED:
				if typeof(license_reason_value) != TYPE_STRING or String(license_reason_value).is_empty():
					findings.append(_finding(
						"error",
						"license_reason",
						"Blocked asset license needs an explicit reason",
						asset_id,
					))
				if license_name_value != null:
					findings.append(_finding(
						"error",
						"license_blocked_name",
						"Blocked asset license cannot claim a license name",
						asset_id,
					))
			elif license_status == LICENSE_CLEARED:
				if typeof(license_name_value) != TYPE_STRING or String(license_name_value).strip_edges().is_empty():
					findings.append(_finding(
						"error",
						"license_name",
						"Cleared asset license needs a non-empty license name",
						asset_id,
					))
				if license_reason_value != null:
					findings.append(_finding(
						"error",
						"license_cleared_reason",
						"Cleared asset license cannot carry a blocking reason",
						asset_id,
					))
				if license_reference.begins_with("http://") or license_reference.begins_with("https://"):
					findings.append(_finding(
						"error",
						"license_cleared_unverifiable",
						"Cleared license must reference locally verifiable evidence",
						asset_id,
					))
			elif license_status == LICENSE_UNKNOWN and (
				typeof(license_reason_value) != TYPE_STRING
				or String(license_reason_value).strip_edges().is_empty()
			):
				findings.append(_finding(
					"error",
					"license_reason",
					"Unknown asset license needs an explicit reason",
					asset_id,
				))

		var links_value: Variant = entry.get("content_links", [])
		if not links_value is Array:
			findings.append(_finding(
				"error",
				"content_links_shape",
				"Content links must be an array",
				asset_id,
			))
		else:
			for link_value in links_value:
				if link_value is String:
					var link := String(link_value)
					if not _is_content_id(link):
						findings.append(_finding(
							"error",
							"content_link_syntax",
							"Content link must use canonical zerkov.* syntax",
							asset_id,
						))
					elif not _KNOWN_CONTENT_LINK_TARGETS.has(link):
						findings.append(_finding(
							"error",
							"content_link_target",
							"Content link does not resolve to a known target: " + link,
							asset_id,
						))
				elif link_value is Dictionary:
					var unresolved := link_value as Dictionary
					var unresolved_id_value: Variant = unresolved.get("id", null)
					var unresolved_status_value: Variant = unresolved.get("status", null)
					var unresolved_reason_value: Variant = unresolved.get("reason", null)
					var unresolved_id := String(unresolved_id_value) if typeof(unresolved_id_value) == TYPE_STRING else ""
					if typeof(unresolved_id_value) != TYPE_STRING or not _is_content_id(unresolved_id):
						findings.append(_finding(
							"error",
							"content_link_syntax",
							"Unresolved content link id must use canonical zerkov.* syntax",
							asset_id,
						))
					if unresolved_status_value != "unresolved_future":
						findings.append(_finding(
							"error",
							"content_link_status",
							"Unresolved content links must declare unresolved_future status",
							asset_id,
						))
					if typeof(unresolved_reason_value) != TYPE_STRING or String(unresolved_reason_value).strip_edges().is_empty():
						findings.append(_finding(
							"error",
							"content_link_reason",
							"Unresolved content links need an explicit reason",
							asset_id,
						))
					if _KNOWN_CONTENT_LINK_TARGETS.has(unresolved_id):
						findings.append(_finding(
							"error",
							"content_link_resolved_status",
							"Known content targets cannot be marked unresolved",
							asset_id,
						))
				else:
					findings.append(_finding(
						"error",
						"content_link_type",
						"Content links must be strings or explicit unresolved objects",
						asset_id,
					))

		var atlas_value: Variant = entry.get("atlas", null)
		if atlas_value != null:
			findings.append_array(_validate_atlas(
				atlas_value,
				asset_id,
				entry,
			))

	for alias in aliases.keys():
		if asset_ids.has(String(alias)) or asset_ids.has(String(alias).to_lower()):
			findings.append(_finding(
				"error",
				"alias_id_collision",
				"Alias collides with an asset id: " + String(alias),
				String(aliases.get(alias, "")),
			))
	return findings


func _validate_atlas(
	value: Variant,
	asset_id: String,
	entry: Dictionary,
) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if not value is Dictionary:
		findings.append(_finding(
			"error",
			"atlas_shape",
			"Atlas metadata must be an object",
			asset_id,
		))
		return findings
	var atlas := value as Dictionary
	var source_size: Variant = atlas.get("source_size", null)
	var cell_size: Variant = atlas.get("cell_size", null)
	if not _is_positive_pair(source_size) or not _is_positive_pair(cell_size):
		findings.append(_finding(
			"error",
			"atlas_size",
			"Atlas source_size and cell_size must be positive integer pairs",
			asset_id,
		))
		return findings
	var source := source_size as Array
	var cell := cell_size as Array
	var columns_value: Variant = atlas.get("columns", null)
	var rows_value: Variant = atlas.get("rows", null)
	var frame_count_value: Variant = atlas.get("frame_count", null)
	if (
		not _is_manifest_positive_int(columns_value)
		or not _is_manifest_positive_int(rows_value)
		or not _is_manifest_positive_int(frame_count_value)
	):
		findings.append(_finding(
			"error",
			"atlas_frames",
			"Atlas columns, rows, and frame_count must be positive JSON integers",
			asset_id,
		))
	else:
		var columns := int(columns_value)
		var rows := int(rows_value)
		var frame_count := int(frame_count_value)
		if columns * int(cell[0]) > int(source[0]) or rows * int(cell[1]) > int(source[1]):
			findings.append(_finding(
				"error",
				"atlas_bounds",
				"Atlas cells exceed the declared source bounds",
				asset_id,
			))
		if columns * rows != frame_count:
			findings.append(_finding(
				"error",
				"atlas_frame_count",
				"Atlas frame_count must equal columns multiplied by rows",
				asset_id,
			))
		var source_path := _source_path_for_entry(entry)
		if not source_path.is_empty() and FileAccess.file_exists(source_path):
			var source_dimensions := _image_dimensions(source_path)
			if source_dimensions == Vector2i.ZERO:
				findings.append(_finding(
					"error",
					"atlas_source_image",
					"Atlas source bytes are not a readable image",
					asset_id,
				))
			elif source_dimensions != Vector2i(int(source[0]), int(source[1])):
				findings.append(_finding(
					"error",
					"atlas_source_dimensions",
					"Atlas source_size does not match source image bytes",
					asset_id,
				))
		var runtime_path := String(entry.get("runtime_path")) if typeof(entry.get("runtime_path")) == TYPE_STRING else ""
		if not runtime_path.is_empty() and FileAccess.file_exists(runtime_path):
			var runtime_dimensions := _image_dimensions(runtime_path)
			if runtime_dimensions == Vector2i.ZERO:
				findings.append(_finding(
					"error",
					"atlas_runtime_image",
					"Atlas runtime bytes are not a readable image",
					asset_id,
				))
			elif runtime_dimensions != Vector2i(int(source[0]), int(source[1])):
				findings.append(_finding(
					"error",
					"atlas_runtime_dimensions",
					"Atlas source_size does not match runtime image bytes",
					asset_id,
				))
	var order_value: Variant = atlas.get("frame_order", null)
	if order_value != null:
		if not order_value is Array:
			findings.append(_finding(
				"error",
				"atlas_frame_order",
				"Atlas frame_order must be an array when present",
				asset_id,
			))
		elif not _is_manifest_integer(frame_count_value) or (order_value as Array).size() != int(frame_count_value):
			findings.append(_finding(
				"error",
				"atlas_frame_order_count",
				"Atlas frame_order must enumerate every frame",
				asset_id,
			))
		else:
			var seen_frames: Dictionary = {}
			for frame_value in order_value:
				if not _is_manifest_integer(frame_value):
					findings.append(_finding(
						"error",
						"atlas_frame_order_type",
						"Atlas frame_order values must be JSON integers",
						asset_id,
					))
				elif int(frame_value) < 0 or int(frame_value) >= int(frame_count_value):
					findings.append(_finding(
						"error",
						"atlas_frame_order_bounds",
						"Atlas frame_order contains an out-of-bounds frame",
						asset_id,
					))
				elif seen_frames.has(int(frame_value)):
					findings.append(_finding(
						"error",
						"atlas_frame_order_duplicate",
						"Atlas frame_order must enumerate each frame exactly once",
						asset_id,
					))
				else:
					seen_frames[int(frame_value)] = true
	return findings

func _is_asset_id(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^zerkov\\.asset\\.[a-z0-9_]+(?:\\.[a-z0-9_]+)*$")
	return regex.search(value) != null


func _is_alias(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[a-z0-9][a-z0-9._-]*$")
	return regex.search(value) != null


func _is_content_id(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^zerkov\\.[a-z0-9_]+(?:\\.[a-z0-9_]+)*$")
	return regex.search(value) != null


func _is_sha256(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[0-9a-f]{64}$")
	return regex.search(value) != null


func _is_positive_pair(value: Variant) -> bool:
	if not value is Array or (value as Array).size() != 2:
		return false
	return _is_manifest_positive_int((value as Array)[0]) and _is_manifest_positive_int((value as Array)[1])


func _positive_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and int(value) > 0


func _nonnegative_int(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and int(value) >= 0


func _is_manifest_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	return false


func _is_manifest_positive_int(value: Variant) -> bool:
	return _is_manifest_integer(value) and int(value) > 0


func _normalize_json_numbers(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in (value as Dictionary).keys():
			result[key] = _normalize_json_numbers((value as Dictionary).get(key))
		return result
	if value is Array:
		var result_array: Array = []
		for item in value:
			result_array.append(_normalize_json_numbers(item))
		return result_array
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and is_equal_approx(float(value), round(float(value))):
		return int(value)
	return value


func _contains_forbidden(value: String, forbidden_paths: Array) -> bool:
	var normalized := value.replace("\\", "/")
	var lowered := normalized.to_lower()
	for segment in normalized.split("/"):
		var segment_lower := String(segment).to_lower()
		if segment_lower.find("do not use") >= 0:
			return true
	for marker_value in forbidden_paths:
		var marker := _string_value(marker_value).to_lower().replace("\\", "/")
		if not marker.is_empty() and lowered.find(marker) >= 0:
			return true
	return false


func _contains_nul(value: String) -> bool:
	return value.to_utf8_buffer().has(0)


func _is_source_root(value: String) -> bool:
	if value.is_empty() or _contains_nul(value) or value.contains("\\"):
		return false
	if value.begins_with("https://"):
		var uri_regex := RegEx.new()
		uri_regex.compile("^https://[^\\s/?#]+(?:/[^\\s?#%]*)?$")
		return uri_regex.search(value) != null and value.find("..") < 0
	if not value.begins_with("/") or value.begins_with("//"):
		return false
	if value.contains("://") or value.contains(":") or value.contains("?") or value.contains("#") or value.contains("%"):
		return false
	var parts := value.split("/")
	for index in range(1, parts.size()):
		if parts[index].is_empty() or parts[index] == "." or parts[index] == "..":
			return false
	return true


func _is_strict_relative_path(value: String) -> bool:
	if value.is_empty() or _contains_nul(value) or value.contains("\\"):
		return false
	if value.begins_with("/") or value.begins_with("~") or value.begins_with("//"):
		return false
	if value.contains("://") or value.contains(":") or value.contains("?") or value.contains("#") or value.contains("%"):
		return false
	var parts := value.split("/")
	for part in parts:
		if part.is_empty() or part == "." or part == "..":
			return false
	return true


func _is_confined_runtime_path(value: String) -> bool:
	if not value.begins_with("res://assets/"):
		return false
	return _is_strict_relative_path(value.trim_prefix("res://"))


func _join_source_path(source_root: String, relative_path: String) -> String:
	return source_root.trim_suffix("/") + "/" + relative_path


func _source_path_for_entry(entry: Dictionary) -> String:
	var provenance_value: Variant = entry.get("provenance", null)
	if not provenance_value is Dictionary:
		return ""
	var provenance := provenance_value as Dictionary
	var root_value: Variant = provenance.get("source_root", null)
	var relative_value: Variant = provenance.get("source_relative_path", null)
	if typeof(root_value) != TYPE_STRING or typeof(relative_value) != TYPE_STRING:
		return ""
	var root := String(root_value)
	var relative := String(relative_value)
	if not root.begins_with("/") or not _is_strict_relative_path(relative):
		return ""
	return _join_source_path(root, relative)


func _image_dimensions(path: String) -> Vector2i:
	if path.is_empty():
		return Vector2i.ZERO
	var image := Image.new()
	if image.load(path) != OK:
		return Vector2i.ZERO
	return image.get_size()


func _validate_license_reference(
	reference: String,
	asset_id: String,
) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if _contains_nul(reference) or reference.contains("\\") or reference.contains(" ") or reference.contains("\t"):
		findings.append(_finding(
			"error",
			"license_reference_syntax",
			"License reference contains unsupported path characters",
			asset_id,
		))
		return findings
	var anchor := ""
	var base := reference
	var anchor_index := reference.find("#")
	if anchor_index >= 0:
		if reference.find("#", anchor_index + 1) >= 0:
			findings.append(_finding(
				"error",
				"license_reference_syntax",
				"License reference may contain at most one anchor",
				asset_id,
			))
			return findings
		base = reference.substr(0, anchor_index)
		anchor = reference.substr(anchor_index + 1)
		var anchor_regex := RegEx.new()
		anchor_regex.compile("^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$")
		if anchor.is_empty() or anchor_regex.search(anchor) == null:
			findings.append(_finding(
				"error",
				"license_reference_anchor",
				"License reference anchor must use canonical dotted segments",
				asset_id,
			))
			return findings
	var file_path := ""
	if base.begins_with("https://"):
		var uri_regex := RegEx.new()
		uri_regex.compile("^https://[^\\s/?#]+(?:/[^\\s?#]*)?$")
		if uri_regex.search(base) == null or base.find("..") >= 0:
			findings.append(_finding(
				"error",
				"license_reference_syntax",
				"License reference HTTPS URI is not canonical",
				asset_id,
			))
		else:
			findings.append(_finding(
				"warning",
				"license_reference_unverifiable",
				"Remote license reference cannot be verified offline",
				asset_id,
			))
		return findings
	elif base.begins_with("res://"):
		var relative_res := base.trim_prefix("res://")
		if not _is_strict_relative_path(relative_res):
			findings.append(_finding(
				"error",
				"license_reference_syntax",
				"res:// license reference must be a strict project-relative path",
				asset_id,
			))
			return findings
		file_path = base
	elif _is_strict_relative_path(base):
		file_path = "res://" + base
	else:
		findings.append(_finding(
			"error",
			"license_reference_syntax",
			"License reference must be res://, HTTPS, or project-relative",
			asset_id,
		))
		return findings
	if not FileAccess.file_exists(file_path):
		findings.append(_finding(
			"error",
			"license_reference_missing",
			"Referenced license evidence does not exist: " + file_path,
			asset_id,
		))
		return findings
	if not anchor.is_empty():
		var file := FileAccess.open(file_path, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
		if file != null:
			file.close()
		if parsed == null or not _json_anchor_exists(parsed, anchor.split(".")):
			findings.append(_finding(
				"error",
				"license_reference_anchor_missing",
				"License reference anchor does not resolve: " + reference,
				asset_id,
			))
	return findings


func _json_anchor_exists(value: Variant, segments: PackedStringArray, index: int = 0) -> bool:
	if index >= segments.size():
		return true
	var segment := String(segments[index])
	if value is Dictionary:
		var dictionary := value as Dictionary
		if not dictionary.has(segment):
			return false
		return _json_anchor_exists(dictionary.get(segment), segments, index + 1)
	if value is Array:
		for item in value:
			if item is Dictionary and String((item as Dictionary).get("id", "")) == segment:
				if _json_anchor_exists(item, segments, index + 1):
					return true
	return false


func _is_unlicensed_art_family(family: String) -> bool:
	return family == "handoff" or family.begins_with("original_") or family == "world_source" or family == "character_source"


func _string_value(value: Variant) -> String:
	return value if value is String else ""


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var digest := _sha256_bytes(file.get_buffer(file.get_length()))
	file.close()
	return digest


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _finding(
	severity: String,
	code: String,
	message: String,
	asset_id: String = "",
) -> Dictionary:
	return {
		"severity": severity,
		"code": code,
		"message": message,
		"asset_id": asset_id,
	}
