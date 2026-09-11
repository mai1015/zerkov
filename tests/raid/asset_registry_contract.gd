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
		if String(provenance.get("source_status", "")) == "available":
			check(source_hash == _string_value(entry.get("runtime_sha256", "")),
				"available source and runtime bytes share the recorded digest: " + asset_id)
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

	var mutated_entry := entries[0].duplicate(true)
	var original_id := String(mutated_entry.get("id", ""))
	mutated_entry["id"] = "zerkov.asset.mutated"
	(mutated_entry.get("provenance", {}) as Dictionary)["source_root"] = "forged"
	check(registry.manifest_fingerprint() == fingerprint,
		"mutating an entries copy cannot change the registry fingerprint")
	check(registry.get_asset(original_id).get("id", "") == original_id,
		"mutating an entries copy cannot change the registry index")
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
	check(imported_count > 0, "curated in-repo assets are represented")
	check(pending_count > 0, "approved absent sheets are represented explicitly")
	check(atlas_count > 0, "explicit atlas metadata is represented")

	print("ASSET_REGISTRY_RESULT checks=", checks, " failures=", failures,
		" entries=", entries.size(), " imported=", imported_count,
		" pending=", pending_count, " atlases=", atlas_count,
		" warnings=", registry.validation_warnings().size())
	quit(0 if failures == 0 else 1)


func _is_sha256(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[0-9a-fA-F]{64}$")
	return regex.search(value) != null


func _string_value(value: Variant) -> String:
	return value if value is String else ""
