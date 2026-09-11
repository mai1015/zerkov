extends SceneTree
## Deterministic Task 3.3 contract.
##
## Run with:
## godot --headless --path . --audio-driver Dummy --script
## res://tests/raid/sawmill_tileset_contract.gd
##
## The selected 32 px source sheet is intentionally still a pending external
## registry row. This contract verifies the authored TileSet source slot and
## all metadata without importing or slicing that sheet (tasks 9.2/9.3).

const TILESET_PATH := "res://game/world/sawmill/sawmill_tileset.tres"
const SOURCE_ASSET_ID := "zerkov.asset.world.exterior_textures"
const SOURCE_ALIAS := "world.exterior.textures"
const SOURCE_SHA256 := "9b09c86b46b9115953362e2a29e48c3f17b5f6cea3e91d95d23727725b91e09a"
const REGISTRY_PATH := "res://game/content/asset_registry.json"
const ZerkovAssetRegistry = preload("res://game/content/zerkov_asset_registry.gd")

const TERRAIN_IDS := ["dirt", "grass", "stone", "water", "road", "sand"]
const NAVIGATION_IDS := ["walkable", "slow", "blocked", "water"]
const COLLISION_IDS := ["none", "solid", "one_way"]
const DRAW_LAYER_IDS := ["ground", "detail", "obstacle", "canopy", "actor", "fx"]
const TILE_REQUIRED_FIELDS := [
	"id",
	"atlas_coord",
	"frame_index",
	"source_asset_id",
	"tile_size_px",
	"terrain_id",
	"navigation_kind",
	"collision_kind",
	"draw_layer",
	"z_index",
]

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SAWMILL_TILESET_CONTRACT: " + message)


func run() -> void:
	var tile_set := ResourceLoader.load(TILESET_PATH, "TileSet") as TileSet
	check(tile_set != null, "authored Sawmill TileSet resource loads")
	if tile_set == null:
		_print_result()
		quit(1)
		return

	_test_native_shape_and_layers(tile_set)
	_test_source_slot(tile_set)
	_test_registry_provenance(tile_set)
	_test_terrain_metadata(tile_set)
	_test_navigation_metadata(tile_set)
	_test_collision_metadata(tile_set)
	_test_draw_layer_metadata(tile_set)
	_test_tile_catalog(tile_set)

	var second := ResourceLoader.load(TILESET_PATH, "TileSet") as TileSet
	check(second != null, "second independent TileSet load succeeds")
	if second != null:
		check(_metadata_signature(tile_set) == _metadata_signature(second),
			"metadata is deterministic across independent loads")
		check(second.get_tile_size() == tile_set.get_tile_size(),
			"native tile geometry is deterministic across independent loads")

	var file_digest := _sha256_file(TILESET_PATH)
	check(_is_sha256(file_digest), "authored TileSet bytes have a SHA-256 digest")
	check(file_digest == _sha256_file(TILESET_PATH),
		"authored TileSet byte fingerprint is stable within the contract")
	_print_result()
	quit(0 if failures == 0 else 1)


func _test_native_shape_and_layers(tile_set: TileSet) -> void:
	check(tile_set.resource_name == "Sawmill Source TileSet",
		"resource name identifies the Sawmill source TileSet")
	check(tile_set.get_tile_shape() == TileSet.TILE_SHAPE_SQUARE,
		"source TileSet uses square cells")
	check(tile_set.get_tile_size() == Vector2i(32, 32),
		"source TileSet cell size is exactly 32 px")
	check(tile_set.is_uv_clipping(), "source TileSet keeps UV clipping enabled")

	check(tile_set.get_physics_layers_count() == 1,
		"one explicit TileSet physics layer is authored")
	if tile_set.get_physics_layers_count() == 1:
		check(tile_set.get_physics_layer_collision_layer(0) == 1,
			"world collision layer uses bit 1")
		check(tile_set.get_physics_layer_collision_mask(0) == 1,
			"world collision mask uses bit 1")
		check(is_equal_approx(tile_set.get_physics_layer_collision_priority(0), 1.0),
			"world collision priority is explicit and stable")

	check(tile_set.get_navigation_layers_count() == 1,
		"one explicit TileSet navigation layer is authored")
	if tile_set.get_navigation_layers_count() == 1:
		check(tile_set.get_navigation_layer_layers(0) == 1,
			"walkable navigation uses bit 1")

	check(tile_set.get_terrain_sets_count() == 1,
		"one explicit terrain set is authored")
	if tile_set.get_terrain_sets_count() == 1:
		check(tile_set.get_terrain_set_mode(0)
			== TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES,
			"terrain set uses corner-and-side matching")
		check(tile_set.get_terrains_count(0) == TERRAIN_IDS.size(),
			"native terrain count matches the authored terrain contract")
		for terrain_index in TERRAIN_IDS.size():
			check(tile_set.get_terrain_name(0, terrain_index) == TERRAIN_IDS[terrain_index],
				"native terrain name is stable: " + TERRAIN_IDS[terrain_index])

	check(tile_set.get_custom_data_layers_count() == 4,
		"source, navigation, collision, and draw custom layers are authored")
	var custom_names := ["source_tile_id", "navigation_kind", "collision_kind", "draw_layer"]
	for layer_index in custom_names.size():
		check(tile_set.get_custom_data_layer_name(layer_index) == custom_names[layer_index],
			"custom data layer name is explicit: " + custom_names[layer_index])
		check(tile_set.get_custom_data_layer_type(layer_index) == TYPE_STRING,
			"custom data layer type is String: " + custom_names[layer_index])

	check(tile_set.get_source_count() == 1,
		"one source atlas slot is reserved for the registry-selected sheet")


func _test_source_slot(tile_set: TileSet) -> void:
	var source := tile_set.get_source(0)
	check(source is TileSetAtlasSource, "source slot uses TileSetAtlasSource")
	if source is TileSetAtlasSource:
		var atlas := source as TileSetAtlasSource
		check(atlas.get_texture_region_size() == Vector2i(32, 32),
			"source atlas region size is exactly 32 px")
		check(atlas.get_tiles_count() == 0,
			"source slot has no guessed slices before task 9.3 authoring")
		check(atlas.get_texture() == null,
			"source slot does not smuggle an unregistered texture import")


func _test_registry_provenance(tile_set: TileSet) -> void:
	var registry := ZerkovAssetRegistry.build_registry()
	check(registry.is_loaded() and registry.is_valid(),
		"curated asset registry remains valid")
	var asset := registry.get_asset(SOURCE_ASSET_ID)
	check(not asset.is_empty(), "source asset resolves by exact registry ID")
	check(registry.resolve_alias(SOURCE_ALIAS).get("id", "") == SOURCE_ASSET_ID,
		"source asset alias resolves exactly, without filename inference")
	check(asset.get("availability", "") == "pending_unimported",
		"source asset keeps its explicit pending import state")
	check(asset.get("runtime_path", "") == "",
		"pending source has no runtime path")
	check(asset.get("runtime_sha256", null) == null,
		"pending source has no runtime digest")
	check(asset.get("family", "") == "world_source" and asset.get("kind", "") == "atlas",
		"source asset remains the curated world atlas row")

	var source_provenance := tile_set.get_meta("sawmill_source_provenance", {}) as Dictionary
	check(tile_set.get_meta("sawmill_schema_version", 0) == 1,
		"Sawmill metadata schema version is explicit")
	check(tile_set.get_meta("sawmill_source_asset_id", "") == SOURCE_ASSET_ID,
		"TileSet links to the exact registry source ID")
	check(tile_set.get_meta("sawmill_source_asset_alias", "") == SOURCE_ALIAS,
		"TileSet records the exact registry alias")
	check(tile_set.get_meta("sawmill_source_registry_id", "") == "zerkov.assets",
		"TileSet records the registry namespace")
	check(tile_set.get_meta("sawmill_source_registry_path", "") == REGISTRY_PATH,
		"TileSet records the registry path")

	var registry_provenance := asset.get("provenance", {}) as Dictionary
	for key in ["source_root", "source_relative_path", "source_status", "source_sha256"]:
		check(source_provenance.get(key, null) == registry_provenance.get(key, null),
			"TileSet provenance matches registry field: " + key)
	check(source_provenance.get("source_sha256", "") == SOURCE_SHA256,
		"source digest is the curated registry digest")
	check(source_provenance.get("availability", "") == "pending_unimported",
		"TileSet discloses pending source availability")
	check(source_provenance.get("runtime_path", "") == ""
		and source_provenance.get("runtime_sha256", "") == "",
		"TileSet does not invent a runtime path or digest")
	check(source_provenance.get("filtering", "") == "nearest"
		and source_provenance.get("mipmaps", true) == false,
		"TileSet records nearest/no-mipmap source policy")
	check(not String(source_provenance.get("source_relative_path", "")).to_lower()
		.contains("do not use"),
		"source provenance does not point to a forbidden directory")


func _test_terrain_metadata(tile_set: TileSet) -> void:
	var values: Variant = tile_set.get_meta("sawmill_terrain_metadata", [])
	check(values is Array and (values as Array).size() == TERRAIN_IDS.size(),
		"terrain metadata enumerates every authored terrain")
	if not values is Array:
		return
	var seen: Dictionary = {}
	for value in values as Array:
		check(value is Dictionary, "terrain metadata row is a dictionary")
		if not value is Dictionary:
			continue
		var row := value as Dictionary
		var terrain_id := String(row.get("id", ""))
		var terrain_index := int(row.get("terrain_index", -1))
		check(TERRAIN_IDS.has(terrain_id), "terrain id is curated: " + terrain_id)
		check(not seen.has(terrain_id), "terrain ids are unique: " + terrain_id)
		seen[terrain_id] = true
		check(int(row.get("terrain_set", -1)) == 0,
			"terrain belongs to the one authored terrain set: " + terrain_id)
		check(terrain_index >= 0 and terrain_index < TERRAIN_IDS.size(),
			"terrain index is in bounds: " + terrain_id)
		check(String(row.get("display_name", "")).strip_edges() != "",
			"terrain display name is explicit: " + terrain_id)
		check(typeof(row.get("walkable", null)) == TYPE_BOOL,
			"terrain walkability is explicit: " + terrain_id)
	check(seen.size() == TERRAIN_IDS.size(), "terrain metadata has no omissions")


func _test_navigation_metadata(tile_set: TileSet) -> void:
	var value: Variant = tile_set.get_meta("sawmill_navigation_metadata", {})
	check(value is Dictionary, "navigation metadata is an object")
	if not value is Dictionary:
		return
	var metadata := value as Dictionary
	check(metadata.get("layer_id", -1) == 0 and metadata.get("layer_bit", 0) == 1,
		"navigation metadata identifies native layer zero and bit one")
	check(metadata.get("layer_name", "") == "sawmill_walkable",
		"navigation layer has a stable name")
	var kinds: Variant = metadata.get("kinds", [])
	check(kinds is Array and (kinds as Array).size() == NAVIGATION_IDS.size(),
		"navigation metadata enumerates all navigation kinds")
	var seen: Dictionary = {}
	if kinds is Array:
		for value_row in kinds as Array:
			check(value_row is Dictionary, "navigation kind is a dictionary")
			if not value_row is Dictionary:
				continue
			var row := value_row as Dictionary
			var kind_id := String(row.get("id", ""))
			check(NAVIGATION_IDS.has(kind_id), "navigation kind is curated: " + kind_id)
			check(not seen.has(kind_id), "navigation kinds are unique: " + kind_id)
			seen[kind_id] = true
			check(typeof(row.get("walkable", null)) == TYPE_BOOL,
				"navigation walkability is explicit: " + kind_id)
			check(typeof(row.get("cost_milli", null)) == TYPE_INT
				and int(row.get("cost_milli", -1)) >= 0,
				"navigation cost is a bounded integer: " + kind_id)
	check(NAVIGATION_IDS.has(String(metadata.get("default_kind", ""))),
		"navigation default kind is enumerated")
	check(seen.size() == NAVIGATION_IDS.size(), "navigation metadata has no omissions")


func _test_collision_metadata(tile_set: TileSet) -> void:
	var value: Variant = tile_set.get_meta("sawmill_collision_metadata", {})
	check(value is Dictionary, "collision metadata is an object")
	if not value is Dictionary:
		return
	var metadata := value as Dictionary
	check(metadata.get("physics_layer_id", -1) == 0,
		"collision metadata identifies native physics layer zero")
	check(metadata.get("collision_layer", 0) == 1
		and metadata.get("collision_mask", 0) == 1,
		"collision metadata records layer and mask bit one")
	check(metadata.get("collision_priority_milli", 0) == 1000,
		"collision priority is an explicit integer")
	var kinds: Variant = metadata.get("kinds", [])
	check(kinds is Array and (kinds as Array).size() == COLLISION_IDS.size(),
		"collision metadata enumerates all collision kinds")
	var seen: Dictionary = {}
	if kinds is Array:
		for value_row in kinds as Array:
			check(value_row is Dictionary, "collision kind is a dictionary")
			if not value_row is Dictionary:
				continue
			var row := value_row as Dictionary
			var kind_id := String(row.get("id", ""))
			check(COLLISION_IDS.has(kind_id), "collision kind is curated: " + kind_id)
			check(not seen.has(kind_id), "collision kinds are unique: " + kind_id)
			seen[kind_id] = true
			check(typeof(row.get("enabled", null)) == TYPE_BOOL
				and typeof(row.get("one_way", null)) == TYPE_BOOL,
				"collision enabled/one-way flags are explicit: " + kind_id)
	check(seen.size() == COLLISION_IDS.size(), "collision metadata has no omissions")


func _test_draw_layer_metadata(tile_set: TileSet) -> void:
	var value: Variant = tile_set.get_meta("sawmill_draw_layer_metadata", [])
	check(value is Array and (value as Array).size() == DRAW_LAYER_IDS.size(),
		"draw-layer metadata enumerates every authored layer")
	if not value is Array:
		return
	var seen: Dictionary = {}
	var last_z := -1
	var has_y_sort := false
	var has_occluding_layer := false
	for value_row in value as Array:
		check(value_row is Dictionary, "draw layer is a dictionary")
		if not value_row is Dictionary:
			continue
		var row := value_row as Dictionary
		var layer_id := String(row.get("id", ""))
		var z_index := int(row.get("z_index", -1))
		check(DRAW_LAYER_IDS.has(layer_id), "draw layer is curated: " + layer_id)
		check(not seen.has(layer_id), "draw layers are unique: " + layer_id)
		seen[layer_id] = true
		check(z_index > last_z, "draw layers have a deterministic front-to-back order")
		last_z = z_index
		check(typeof(row.get("y_sort", null)) == TYPE_BOOL
			and typeof(row.get("occludes", null)) == TYPE_BOOL,
			"draw-layer sorting/occlusion flags are explicit: " + layer_id)
		has_y_sort = has_y_sort or bool(row.get("y_sort", false))
		has_occluding_layer = has_occluding_layer or bool(row.get("occludes", false))
	check(seen.size() == DRAW_LAYER_IDS.size(), "draw-layer metadata has no omissions")
	check(has_y_sort, "actor draw layer explicitly enables y-sort")
	check(has_occluding_layer, "obstacle/canopy draw layers explicitly occlude")


func _test_tile_catalog(tile_set: TileSet) -> void:
	var atlas: Variant = tile_set.get_meta("sawmill_source_atlas", {})
	check(atlas is Dictionary, "source atlas metadata is an object")
	if not atlas is Dictionary:
		return
	var source_size := (atlas as Dictionary).get("source_size", []) as Array
	var cell_size := (atlas as Dictionary).get("cell_size", []) as Array
	var columns := int((atlas as Dictionary).get("columns", 0))
	var rows := int((atlas as Dictionary).get("rows", 0))
	var frame_count := int((atlas as Dictionary).get("frame_count", 0))
	check(source_size == [704, 704], "source atlas dimensions are explicit")
	check(cell_size == [32, 32], "source atlas cell dimensions are explicit")
	check(columns == 22 and rows == 22 and frame_count == 484,
		"source atlas grid is the registry-declared 22x22 grid")
	check(columns * cell_size[0] == source_size[0]
		and rows * cell_size[1] == source_size[1],
		"source atlas cells fit the declared source bounds")
	check(columns * rows == frame_count, "source atlas frame count is deterministic")

	var values: Variant = tile_set.get_meta("sawmill_tile_catalog", [])
	check(values is Array and not (values as Array).is_empty(),
		"source TileSet carries an explicit semantic tile catalog")
	if not values is Array:
		return
	var ids: Dictionary = {}
	var coords: Dictionary = {}
	var terrains: Dictionary = {}
	var navigations: Dictionary = {}
	var collisions: Dictionary = {}
	var draw_layers: Dictionary = {}
	for value_row in values as Array:
		check(value_row is Dictionary, "tile catalog row is a dictionary")
		if not value_row is Dictionary:
			continue
		var row := value_row as Dictionary
		for required in TILE_REQUIRED_FIELDS:
			check(row.has(required), "tile row has explicit field %s" % required)
		var tile_id := String(row.get("id", ""))
		check(tile_id.begins_with("zerkov.tile.sawmill."),
			"tile id uses the stable Sawmill namespace: " + tile_id)
		check(not ids.has(tile_id), "tile ids are unique: " + tile_id)
		ids[tile_id] = true
		check(row.get("source_asset_id", "") == SOURCE_ASSET_ID,
			"tile links to the exact registry source ID: " + tile_id)
		var coord := row.get("atlas_coord", []) as Array
		check(coord.size() == 2 and typeof(coord[0]) == TYPE_INT
			and typeof(coord[1]) == TYPE_INT,
			"tile atlas coordinate is an integer pair: " + tile_id)
		if coord.size() == 2:
			var key := "%d,%d" % [int(coord[0]), int(coord[1])]
			check(int(coord[0]) >= 0 and int(coord[0]) < columns
				and int(coord[1]) >= 0 and int(coord[1]) < rows,
				"tile atlas coordinate is within source bounds: " + tile_id)
			check(not coords.has(key), "tile atlas coordinates are unique: " + key)
			coords[key] = true
			check(int(row.get("frame_index", -1)) == int(coord[1]) * columns + int(coord[0]),
				"tile frame index is derived from explicit coordinates: " + tile_id)
		check(row.get("tile_size_px", []) == [32, 32],
			"tile records the 32 px source cell size: " + tile_id)
		var terrain_id := String(row.get("terrain_id", ""))
		var navigation_kind := String(row.get("navigation_kind", ""))
		var collision_kind := String(row.get("collision_kind", ""))
		var draw_layer := String(row.get("draw_layer", ""))
		check(TERRAIN_IDS.has(terrain_id), "tile terrain is enumerated: " + tile_id)
		check(NAVIGATION_IDS.has(navigation_kind), "tile navigation is enumerated: " + tile_id)
		check(COLLISION_IDS.has(collision_kind), "tile collision is enumerated: " + tile_id)
		check(DRAW_LAYER_IDS.has(draw_layer), "tile draw layer is enumerated: " + tile_id)
		terrains[terrain_id] = true
		navigations[navigation_kind] = true
		collisions[collision_kind] = true
		draw_layers[draw_layer] = true
		check(typeof(row.get("z_index", null)) == TYPE_INT,
			"tile draw z-index is an integer: " + tile_id)
	check(terrains.size() == TERRAIN_IDS.size(), "tile catalog covers every terrain")
	check(navigations.size() == NAVIGATION_IDS.size(), "tile catalog covers every navigation kind")
	check(collisions.size() == COLLISION_IDS.size(), "tile catalog covers every collision kind")
	check(draw_layers.size() == DRAW_LAYER_IDS.size(), "tile catalog covers every draw layer")


func _metadata_signature(tile_set: TileSet) -> String:
	var keys := [
		"sawmill_schema_version",
		"sawmill_source_asset_id",
		"sawmill_source_asset_alias",
		"sawmill_source_registry_id",
		"sawmill_source_registry_path",
		"sawmill_source_provenance",
		"sawmill_source_atlas",
		"sawmill_terrain_metadata",
		"sawmill_navigation_metadata",
		"sawmill_collision_metadata",
		"sawmill_draw_layer_metadata",
		"sawmill_tile_catalog",
	]
	var encoded := PackedStringArray()
	for key in keys:
		encoded.append(_canonical_json(tile_set.get_meta(key, null)))
	return _sha256_text("|".join(encoded))


func _canonical_json(value: Variant) -> String:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var keys := PackedStringArray()
		for key in dictionary.keys():
			keys.append(String(key))
		keys.sort()
		var pairs := PackedStringArray()
		for key in keys:
			pairs.append(JSON.stringify(key) + ":" + _canonical_json(dictionary.get(key)))
		return "{" + ",".join(pairs) + "}"
	if value is Array:
		var items := PackedStringArray()
		for item in value as Array:
			items.append(_canonical_json(item))
		return "[" + ",".join(items) + "]"
	return JSON.stringify(value)


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


func _sha256_text(value: String) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(value.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


func _is_sha256(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[0-9a-f]{64}$")
	return regex.search(value) != null


func _print_result() -> void:
	print("SAWMILL_TILESET_RESULT checks=", checks, " failures=", failures,
		" source_asset=", SOURCE_ASSET_ID, " source_status=pending_unimported")
