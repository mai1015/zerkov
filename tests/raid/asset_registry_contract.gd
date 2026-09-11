extends SceneTree
## Run with:
## godot --headless --path . --audio-driver Dummy --script
## res://tests/raid/asset_registry_contract.gd

const ZerkovAssetRegistry = preload("res://game/content/zerkov_asset_registry.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("ASSET_REGISTRY_CONTRACT: " + message)


func run() -> void:
	var registry := ZerkovAssetRegistry.build_registry()
	check(registry != null, "registry builds from the checked-in JSON manifest")
	if registry == null:
		print("ASSET_REGISTRY_RESULT checks=", checks, " failures=", failures)
		quit(1)
		return

	check(registry.is_loaded(), "manifest is readable")
	check(registry.is_valid(), "manifest has no structural or runtime-path errors")
	if not registry.is_valid():
		for finding in registry.validation_errors():
			print("ASSET_REGISTRY_ERROR ", finding)
	var fingerprint := registry.manifest_fingerprint()
	check(_is_sha256(fingerprint), "manifest fingerprint is a SHA-256 digest")
	var second := ZerkovAssetRegistry.build()
	check(second.manifest_fingerprint() == fingerprint,
		"manifest fingerprint is deterministic across independent loads")

	var entries := registry.entries()
	check(entries.size() >= 1, "registry contains curated entries")
	var ids: Dictionary = {}
	var aliases: Dictionary = {}
	var imported_count := 0
	var pending_count := 0
	var atlas_count := 0
	for value in entries:
		check(value is Dictionary, "each registry row is a dictionary")
		if not value is Dictionary:
			continue
		var entry := value as Dictionary
		var asset_id := String(entry.get("id", ""))
		check(asset_id.begins_with("zerkov.asset."),
			"asset id stays in the game-owned namespace: " + asset_id)
		check(not ids.has(asset_id), "asset ids are unique: " + asset_id)
		ids[asset_id] = true
		var row_aliases: Variant = entry.get("aliases", [])
		check(row_aliases is Array and not (row_aliases as Array).is_empty(),
			"asset has at least one exact alias: " + asset_id)
		if row_aliases is Array:
			for alias_value in row_aliases:
				var alias := String(alias_value)
				check(not aliases.has(alias), "runtime aliases are unique: " + alias)
				aliases[alias] = asset_id
				var resolved := registry.resolve_alias(alias)
				check(String(resolved.get("id", "")) == asset_id,
					"exact alias resolves to its owning asset: " + alias)
		var availability := String(entry.get("availability", ""))
		if availability == ZerkovAssetRegistry.AVAILABILITY_PENDING_UNIMPORTED:
			pending_count += 1
			check(_string_value(entry.get("runtime_path", "")).is_empty(),
				"pending asset has no runtime path: " + asset_id)
			check(_string_value(entry.get("runtime_sha256", "")).is_empty(),
				"pending asset has no runtime hash: " + asset_id)
		else:
			imported_count += 1
			var runtime_path := _string_value(entry.get("runtime_path", ""))
			check(runtime_path.begins_with("res://assets/"),
				"imported runtime path is confined: " + runtime_path)
			check(_is_sha256(_string_value(entry.get("runtime_sha256", ""))),
				"imported asset carries a runtime hash: " + asset_id)
		var provenance := entry.get("provenance", {}) as Dictionary
		check(not _string_value(provenance.get("source_root", "")).is_empty(),
			"source root is explicit: " + asset_id)
		check(not _string_value(provenance.get("source_relative_path", "")).is_empty(),
			"source-relative path is explicit: " + asset_id)
		var source_hash := _string_value(provenance.get("source_sha256", ""))
		check(source_hash.is_empty() or _is_sha256(source_hash),
			"source hash is null or valid: " + asset_id)
		var source_status := String(provenance.get("source_status", ""))
		if source_status == "available":
			check(source_hash == _string_value(entry.get("runtime_sha256", "")),
				"available source and runtime bytes share the recorded digest: " + asset_id)
		if source_status == "available" or source_status == "available_external":
			var source_root := _string_value(provenance.get("source_root", ""))
			var source_relative := _string_value(provenance.get("source_relative_path", ""))
			var source_path := source_root.trim_suffix("/") + "/" + source_relative
			if source_root.begins_with("/") and FileAccess.file_exists(source_path):
				check(_sha256_file(source_path) == source_hash,
					"locally available source bytes match their recorded digest: " + asset_id)
		var filtering := entry.get("filtering", {}) as Dictionary
		check(filtering.has("mode") and filtering.has("mipmaps"),
			"filtering and mipmap policy are explicit: " + asset_id)
		check(String(entry.get("family", "")).is_empty() == false,
			"asset family is explicit: " + asset_id)
		check(String(entry.get("kind", "")).is_empty() == false,
			"asset kind is explicit: " + asset_id)
		var license := entry.get("license", {}) as Dictionary
		check(String(license.get("status", "")).is_empty() == false,
			"license status is explicit: " + asset_id)
		check(String(license.get("reference", "")).is_empty() == false,
			"license reference is explicit: " + asset_id)
		var links: Variant = entry.get("content_links", [])
		check(links is Array, "content links are an explicit array: " + asset_id)
		if links is Array:
			for link_value in links:
				check(String(link_value).begins_with("zerkov."),
					"content link is explicit and namespaced: " + asset_id)
		var atlas: Variant = entry.get("atlas", null)
		if atlas != null:
			atlas_count += 1
			check(atlas is Dictionary, "atlas metadata is an object: " + asset_id)
			if atlas is Dictionary:
				var atlas_data := atlas as Dictionary
				var source_size := atlas_data.get("source_size", []) as Array
				var cell_size := atlas_data.get("cell_size", []) as Array
				check(source_size.size() == 2 and cell_size.size() == 2,
					"atlas source/cell sizes are explicit: " + asset_id)
				check(int(atlas_data.get("columns", 0)) > 0
					and int(atlas_data.get("rows", 0)) > 0
					and int(atlas_data.get("frame_count", 0)) > 0,
					"atlas frame dimensions are positive: " + asset_id)

	for background_id in [
		"zerkov.asset.original.ui.background.clouds",
		"zerkov.asset.original.ui.background.foreground",
		"zerkov.asset.original.ui.background.house",
		"zerkov.asset.original.ui.background.logo_clouds",
		"zerkov.asset.original.ui.background.mountains",
		"zerkov.asset.original.ui.background.sky",
	]:
		var background := registry.get_asset(background_id)
		var background_provenance := background.get("provenance", {}) as Dictionary
		check(background_provenance.get("source_root", "")
				== "/Volumes/Data/Assets/zerkov/UI/UI",
			"UI background source root is canonical: " + background_id)
		check(not String(background_provenance.get("source_relative_path", ""))
				.begins_with("UI/"),
			"UI background source path does not duplicate the UI directory: " + background_id)
		check(background_provenance.get("source_status", "") == "available",
			"UI background source is locally available: " + background_id)
		check(background_provenance.get("source_sha256", "")
				== background.get("runtime_sha256", ""),
			"UI background source and runtime hashes match: " + background_id)

	var sawmill := registry.get_asset("zerkov.asset.world.sawmill.prop_sheet")
	check(not sawmill.is_empty(), "Sawmill prop sheet uses an honest stable id")
	check(registry.get_asset("zerkov.asset.world.sawmill.layout").is_empty(),
		"stale Sawmill layout id is not retained")
	check(sawmill.get("kind", "") == "prop_sheet",
		"Sawmill source is classified as a pixel-art prop sheet")
	check((sawmill.get("filtering", {}) as Dictionary).get("mode", "") == "nearest"
		and (sawmill.get("filtering", {}) as Dictionary).get("mipmaps", true) == false,
		"Sawmill prop sheet uses nearest filtering without mipmaps")
	check(String((sawmill.get("provenance", {}) as Dictionary).get("source_relative_path", ""))
			== "Lumber Yard/Lumber yard.png",
		"Sawmill source filename is preserved exactly")

	var blockers := registry.distribution_blockers()
	var blocker_ids: Dictionary = {}
	for blocker_value in blockers:
		var blocker := blocker_value as Dictionary
		var blocker_id := String(blocker.get("id", ""))
		blocker_ids[blocker_id] = true
		check(String(blocker.get("status", "")) == "blocked",
			"distribution blocker remains blocked: " + blocker_id)
		check(not String(blocker.get("reference", "")).is_empty(),
			"distribution blocker has a canonical reference: " + blocker_id)
		check(not String(blocker.get("reason", "")).is_empty(),
			"distribution blocker has an actionable reason: " + blocker_id)
	for expected in [
		"inventory_system",
		"weapon_system",
		"zerkov-handoff-and-original-art",
	]:
		check(blocker_ids.has(expected),
			"existing distribution blocker is surfaced: " + expected)

	check(registry.resolve_alias("ITEM.WEAPON.AKM").is_empty(),
		"case-folded aliases are not accepted")
	check(registry.resolve_alias("item.weapon.akm").get("id", "")
			== "zerkov.asset.handoff.akm",
		"AKM alias remains exact and stable")
	check(registry.get_asset("zerkov.item.weapon.akm").is_empty(),
		"canonical content ids are not accepted as asset ids")

	var original_id := String((entries[0] as Dictionary).get("id", ""))
	var returned_entry := registry.get_asset(original_id)
	returned_entry["id"] = "zerkov.asset.mutated"
	(returned_entry.get("provenance", {}) as Dictionary)["source_root"] = "forged"
	(returned_entry["aliases"] as Array)[0] = "forged.alias"
	check(registry.manifest_fingerprint() == fingerprint,
		"mutating a directly returned entry cannot change the registry fingerprint")
	check(registry.get_asset(original_id).get("id", "") == original_id,
		"mutating a directly returned entry cannot change the registry index")
	check(registry.resolve_alias("forged.alias").is_empty(),
		"mutating a directly returned alias list cannot change the alias index")
	var manifest_copy := registry.manifest()
	(manifest_copy.get("assets", []) as Array)[0]["id"] = "zerkov.asset.mutated"
	check(registry.get_asset(original_id).get("id", "") == original_id,
		"mutating a manifest copy cannot change the registry")

	var warning_codes: Dictionary = {}
	for finding_value in registry.validation_warnings():
		warning_codes[String(finding_value.get("code", ""))] = true
	check(warning_codes.has("source_provenance_missing"),
		"missing handoff provenance is surfaced as a warning")
	check(warning_codes.has("pending_unimported"),
		"absent approved-slice sheets are surfaced as pending")
	_run_negative_probes(registry)
	check(imported_count > 0, "curated in-repo assets are represented")
	check(pending_count > 0, "approved absent sheets are represented explicitly")
	check(atlas_count > 0, "explicit atlas metadata is represented")

	print("ASSET_REGISTRY_RESULT checks=", checks, " failures=", failures,
		" entries=", entries.size(), " imported=", imported_count,
		" pending=", pending_count, " atlases=", atlas_count,
		" warnings=", registry.validation_warnings().size(),
		" negative_probes=21")
	quit(0 if failures == 0 else 1)


func _run_negative_probes(registry: ZerkovAssetRegistry) -> void:
	var candidate := registry.manifest()
	_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["runtime_path"] = "res://assets/../outside.png"
	_expect_rejection(candidate, "runtime_path", "runtime traversal is rejected")

	candidate = registry.manifest()
	_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["runtime_path"] = "res://assets\\outside.png"
	_expect_rejection(candidate, "runtime_path", "Windows runtime separators are rejected")

	candidate = registry.manifest()
	(_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["provenance"] as Dictionary)["source_relative_path"] = "../escape.png"
	_expect_rejection(candidate, "provenance_path", "source traversal is rejected")

	candidate = registry.manifest()
	var hostile_provenance := _entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["provenance"] as Dictionary
	hostile_provenance["source_root"] = "C:\\Assets\\zerkov"
	hostile_provenance["source_relative_path"] = "res://sprite.png"
	_expect_rejections(candidate, ["source_root", "provenance_path"], "Windows and URI provenance are rejected")

	candidate = registry.manifest()
	(_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["provenance"] as Dictionary)["source_relative_path"] = "Characters (dO nOt UsE)/sprite.png"
	_expect_rejection(candidate, "provenance_forbidden", "case-insensitive DO NOT USE segments are rejected")

	candidate = registry.manifest()
	var missing_source := _entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["provenance"] as Dictionary
	missing_source["source_root"] = "/Volumes/Data/Assets/zerkov/not-present"
	_expect_rejection(candidate, "source_missing", "available source must exist")

	candidate = registry.manifest()
	(_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["provenance"] as Dictionary)["source_sha256"] = String("0").repeat(64)
	_expect_rejection(candidate, "source_hash_mismatch", "available source bytes must match their digest")

	candidate = registry.manifest()
	candidate["schema_version"] = 1.0
	_expect_rejection(candidate, "schema_version_type", "schema version must be an integer")

	candidate = registry.manifest()
	candidate["schema_version"] = 1.000001
	_expect_rejection(candidate, "schema_version_type", "near-integer schema version must be rejected")

	candidate = registry.manifest()
	candidate["content_version"] = 1.000001
	_expect_rejection(candidate, "content_version", "near-integer content version must be rejected")

	candidate = registry.manifest()
	var near_source_size := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_source_size["source_size"] = [384.000001, 64]
	_expect_rejection(candidate, "atlas_size", "near-integer atlas source dimensions must be rejected")

	candidate = registry.manifest()
	var near_cell_size := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_cell_size["cell_size"] = [64.000001, 64]
	_expect_rejection(candidate, "atlas_size", "near-integer atlas cell dimensions must be rejected")

	candidate = registry.manifest()
	var near_columns := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_columns["columns"] = 6.000001
	_expect_rejection(candidate, "atlas_frames", "near-integer atlas columns must be rejected")

	candidate = registry.manifest()
	var near_rows := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_rows["rows"] = 1.000001
	_expect_rejection(candidate, "atlas_frames", "near-integer atlas rows must be rejected")

	candidate = registry.manifest()
	var near_frame_count := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_frame_count["frame_count"] = 6.000001
	_expect_rejection(candidate, "atlas_frames", "near-integer atlas frame count must be rejected")

	candidate = registry.manifest()
	var near_frame_order := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	near_frame_order["frame_order"] = [0.000001, 1, 2, 3, 4, 5]
	_expect_rejection(candidate, "atlas_frame_order_type", "near-integer frame order values must be rejected")

	candidate = registry.manifest()
	_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["availability"] = true
	_expect_rejection(candidate, "availability_type", "availability must be a string")

	candidate = registry.manifest()
	(_entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["aliases"] as Array)[0] = 42
	_expect_rejection(candidate, "alias_type", "aliases must contain strings")

	candidate = registry.manifest()
	var bad_atlas := _entry_for(candidate, "zerkov.asset.world.exterior.props")["atlas"] as Dictionary
	bad_atlas["source_size"] = [1, 1]
	_expect_rejection(candidate, "atlas_bounds", "atlas cells must fit declared dimensions")

	candidate = registry.manifest()
	var duplicate_order := _entry_for(candidate, "zerkov.asset.character.npc1.idle")["atlas"] as Dictionary
	duplicate_order["frame_order"] = [0, 0, 1, 2, 3, 4]
	_expect_rejection(candidate, "atlas_frame_order_duplicate", "atlas frame_order must be nonduplicate")

	candidate = registry.manifest()
	var bad_links := _entry_for(candidate, "zerkov.asset.handoff.akm")
	bad_links["content_links"] = ["zerkov.item.not_real", "not-a-content-id"]
	var bad_license := _entry_for(candidate, "zerkov.asset.original.ammo.standard_762x39")["license"] as Dictionary
	bad_license["status"] = true
	bad_license["reference"] = "res://missing/LICENSE.txt"
	_expect_rejections(
		candidate,
		["content_link_target", "content_link_syntax", "license_status_type", "license_reference_missing"],
		"dangling content links and dishonest license evidence are rejected",
	)


func _entry_for(manifest: Dictionary, asset_id: String) -> Dictionary:
	var values: Variant = manifest.get("assets", [])
	if values is Array:
		for value in values:
			if value is Dictionary and String((value as Dictionary).get("id", "")) == asset_id:
				return value as Dictionary
	return {}


func _expect_rejection(candidate: Dictionary, code: String, label: String) -> void:
	_expect_rejections(candidate, [code], label)


func _expect_rejections(candidate: Dictionary, codes: Array, label: String) -> void:
	var findings: Array[Dictionary] = ZerkovAssetRegistry.validate_candidate(candidate)
	for code_value in codes:
		var code := String(code_value)
		check(_has_error_code(findings, code),
			"negative probe rejected with " + code + ": " + label)


func _has_error_code(findings: Array[Dictionary], code: String) -> bool:
	for finding in findings:
		if String(finding.get("severity", "")) == "error" and String(finding.get("code", "")) == code:
			return true
	return false


func _is_sha256(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[0-9a-fA-F]{64}$")
	return regex.search(value) != null


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	if context.update(file.get_buffer(file.get_length())) != OK:
		file.close()
		return ""
	var digest := context.finish().hex_encode()
	file.close()
	return digest


func _string_value(value: Variant) -> String:
	return value if value is String else ""
