extends SceneTree
## Headless Task 3.3 contract for the project-owned Sawmill source TileSet.
##
## This contract intentionally validates the native TileSetAtlasSource, not a
## metadata-only placeholder.  It loads the resource twice with
## CACHE_MODE_IGNORE, validates every stable ID through ZIdentityRules, and
## runs in-memory fail-before/repair probes for each required native surface.
## It does not open a window, create a viewport, or execute layout code.

const TILESET_PATH: String = "res://game/world/sawmill/sawmill_tileset.tres"
const MANIFEST_PATH: String = "res://game/world/sawmill/sawmill_greybox_manifest.json"
const ATLAS_PATH: String = "res://assets/world/sawmill/sawmill_greybox_atlas.svg"
const LICENSE_PATH: String = "res://licenses/zerkov-sawmill-greybox-MIT.txt"
const SOURCE_ASSET_ID: String = "zerkov.asset.world.sawmill.greybox_atlas"
const SOURCE_ALIAS: String = "world.sawmill.greybox_atlas"
const SOURCE_SHA256: String = "1af26d2e20a781334ba155381bb64d5c750b84a375a84a4669feb9bbc1b071ad"
const LICENSE_SHA256: String = "c6aa1ec133530b941e0c1d36aec6c0cffc93626f828e94c5e37d400fc26a1709"
const REGISTRY_PATH: String = "res://game/content/asset_registry.json"
const IDENTITY_RULES = preload("res://game/domain/z_identity_rules.gd")
const ZerkovAssetRegistry = preload("res://game/content/zerkov_asset_registry.gd")

const TERRAIN_IDS := ["dirt", "grass", "stone", "water", "road", "sand"]
const NAVIGATION_IDS := ["walkable", "slow", "blocked", "water"]
const COLLISION_IDS := ["none", "solid", "one_way"]
const DRAW_LAYER_IDS := ["ground", "detail", "obstacle", "canopy", "actor", "fx"]
const CUSTOM_DATA_NAMES := ["source_tile_id", "navigation_kind", "collision_kind", "draw_layer"]
const PEERING_BITS := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_TOP_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
]
const PEERING_NAMES := [
	"right_side",
	"bottom_right_corner",
	"bottom_side",
	"bottom_left_corner",
	"left_side",
	"top_left_corner",
	"top_side",
	"top_right_corner",
]
const PEERING_VALUES := [0, 3, 4, 7, 8, 11, 12, 15]

var checks: int = 0
var failures: int = 0
var manifest: Dictionary = {}


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SAWMILL_TILESET_CONTRACT: " + message)


func run() -> void:
	_load_manifest()
	check(not manifest.is_empty(), "semantic manifest loads as a JSON object")
	if manifest.is_empty():
		_print_result()
		quit(1)
		return

	_test_manifest()
	_test_registry_provenance()

	var first_resource: Resource = ResourceLoader.load(
		TILESET_PATH, "TileSet", ResourceLoader.CACHE_MODE_IGNORE
	)
	var first_tile_set := first_resource as TileSet
	check(first_tile_set != null, "authored Sawmill TileSet loads with CACHE_MODE_IGNORE")
	if first_tile_set == null:
		_print_result()
		quit(1)
		return

	_test_native_shape(first_tile_set)
	_test_native_tiles(first_tile_set)
	_test_tilemap_polygon_bounds(first_tile_set)
	_test_metadata(first_tile_set)
	_test_repair_probes(first_tile_set)

	var second_resource: Resource = ResourceLoader.load(
		TILESET_PATH, "TileSet", ResourceLoader.CACHE_MODE_IGNORE
	)
	var second_tile_set := second_resource as TileSet
	check(second_tile_set != null, "second uncached TileSet load succeeds")
	if second_tile_set != null:
		check(first_resource.get_instance_id() != second_resource.get_instance_id(),
			"CACHE_MODE_IGNORE produces distinct resource instances")
		check(_metadata_signature(first_tile_set) == _metadata_signature(second_tile_set),
			"metadata is deterministic across distinct uncached loads")
		check(_native_signature(first_tile_set) == _native_signature(second_tile_set),
			"native atlas coordinates and TileData are deterministic across distinct uncached loads")

	_print_result()
	quit(0 if failures == 0 else 1)


func _load_manifest() -> void:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		manifest = parsed as Dictionary


func _test_manifest() -> void:
	_check_stable_id(_string_value(manifest.get("stable_id", "")), &"manifest", "manifest stable ID")
	_check_stable_id(_string_value(manifest.get("atlas_asset_id", "")), &"asset", "manifest atlas asset ID")
	check(manifest.get("atlas_asset_id", "") == SOURCE_ASSET_ID,
		"manifest names the project-owned greybox registry asset")
	check(manifest.get("atlas_alias", "") == SOURCE_ALIAS,
		"manifest names the exact greybox registry alias")
	check(manifest.get("source_path", "") == ATLAS_PATH,
		"manifest source path is the project-owned SVG")
	check(manifest.get("source_root", "") == "res://",
		"manifest provenance root is stable across project checkouts")
	check(manifest.get("runtime_path", "") == ATLAS_PATH,
		"manifest runtime path is the project-owned SVG")
	check(not _string_value(manifest.get("source_path", "")).to_lower().contains("exterior"),
		"manifest does not use the pending external Exterior Textures source")
	check(not _string_value(manifest.get("source_relative_path", "")).to_lower().contains("do not use"),
		"manifest provenance does not point into a forbidden path")
	check(manifest.get("source_status", "") == "available",
		"manifest source status is explicitly available")
	check(manifest.get("source_sha256", "") == SOURCE_SHA256,
		"manifest records the immutable greybox SVG digest")
	check(manifest.get("runtime_sha256", "") == SOURCE_SHA256,
		"manifest records the matching runtime digest")
	check(_sha256_file(ATLAS_PATH) == SOURCE_SHA256,
		"project-owned SVG bytes match the manifest digest")

	var license := _dictionary_value(manifest.get("license", {}))
	check(license.get("name", "") == "MIT", "greybox atlas license is explicitly MIT")
	check(license.get("reference", "") == LICENSE_PATH,
		"greybox atlas license points to the checked-in license text")
	check(_sha256_file(LICENSE_PATH) == LICENSE_SHA256,
		"checked-in license text has the recorded digest")

	var authoring := _dictionary_value(manifest.get("authoring", {}))
	check(authoring.get("kind", "") == "project_owned_greybox",
		"atlas authoring kind is project-owned greybox")
	check(authoring.get("method", "") == "text-authored SVG",
		"atlas authoring method is explicit text-authored SVG")
	check(authoring.get("external_source_dependency", true) == false,
		"atlas authoring has no external source dependency")
	check(authoring.get("task_9_3_dependency", true) == false,
		"atlas authoring has no Task 9.3 dependency")

	check(_integer_pair_equals(manifest.get("tile_size_px", []), Vector2i(32, 32)), "manifest tile size is exactly 32 px")
	check(_integer_pair_equals(manifest.get("source_size_px", []), Vector2i(128, 128)), "manifest source size is 128 by 128 px")
	check(manifest.get("columns", 0) == 4 and manifest.get("rows", 0) == 4,
		"manifest source grid is four by four")
	check(manifest.get("frame_count", 0) == 16, "manifest frame count is sixteen")

	_test_manifest_terrain()
	_test_manifest_navigation()
	_test_manifest_collision()
	_test_manifest_draw_layers()
	_test_manifest_peering()
	_test_manifest_tiles()


func _test_manifest_terrain() -> void:
	var terrain_set := _dictionary_value(manifest.get("terrain_set", {}))
	_check_stable_id(_string_value(terrain_set.get("stable_id", "")), &"terrain_set", "terrain-set stable ID")
	check(terrain_set.get("index", -1) == 0, "terrain set index is zero")
	check(terrain_set.get("mode", "") == "match_corners_and_sides",
		"manifest terrain mode is corner-and-side matching")
	var terrains := _array_value(terrain_set.get("terrains", []))
	check(terrains.size() == TERRAIN_IDS.size(), "manifest enumerates every terrain")
	for index in range(min(terrains.size(), TERRAIN_IDS.size())):
		var row := _dictionary_value(terrains[index])
		var terrain_id := _string_value(row.get("id", ""))
		_check_stable_id(_string_value(row.get("stable_id", "")), &"terrain", "terrain stable ID " + terrain_id)
		_check_part(terrain_id, "terrain short ID " + terrain_id)
		check(terrain_id == TERRAIN_IDS[index], "terrain order is deterministic: " + terrain_id)
		check(row.get("index", -1) == index, "terrain index is explicit: " + terrain_id)
		check(typeof(row.get("walkable", null)) == TYPE_BOOL,
			"terrain walkability is explicit: " + terrain_id)


func _test_manifest_navigation() -> void:
	var navigation := _dictionary_value(manifest.get("navigation", {}))
	_check_stable_id(_string_value(navigation.get("stable_id", "")), &"navigation_layer", "navigation layer stable ID")
	check(navigation.get("layer_id", -1) == 0 and navigation.get("layer_bit", 0) == 1,
		"navigation layer is native layer zero with bit one")
	var kinds := _array_value(navigation.get("kinds", []))
	check(kinds.size() == NAVIGATION_IDS.size(), "manifest enumerates every navigation kind")
	for index in range(min(kinds.size(), NAVIGATION_IDS.size())):
		var row := _dictionary_value(kinds[index])
		var kind_id := _string_value(row.get("id", ""))
		_check_stable_id(_string_value(row.get("stable_id", "")), &"navigation", "navigation stable ID " + kind_id)
		_check_part(kind_id, "navigation short ID " + kind_id)
		check(kind_id == NAVIGATION_IDS[index], "navigation kind order is deterministic: " + kind_id)
		check(typeof(row.get("walkable", null)) == TYPE_BOOL,
			"navigation walkability is explicit: " + kind_id)
		check(_integer_like(row.get("cost_milli", null)) and int(row.get("cost_milli", -1)) >= 0,
			"navigation cost is a bounded integer: " + kind_id)


func _test_manifest_collision() -> void:
	var collision := _dictionary_value(manifest.get("collision", {}))
	_check_stable_id(_string_value(collision.get("stable_id", "")), &"collision_layer", "collision layer stable ID")
	check(collision.get("physics_layer_id", -1) == 0,
		"collision layer is native physics layer zero")
	check(collision.get("collision_layer", 0) == 1 and collision.get("collision_mask", 0) == 1,
		"collision layer and mask use bit one")
	var kinds := _array_value(collision.get("kinds", []))
	check(kinds.size() == COLLISION_IDS.size(), "manifest enumerates every collision kind")
	for index in range(min(kinds.size(), COLLISION_IDS.size())):
		var row := _dictionary_value(kinds[index])
		var kind_id := _string_value(row.get("id", ""))
		_check_stable_id(_string_value(row.get("stable_id", "")), &"collision", "collision stable ID " + kind_id)
		_check_part(kind_id, "collision short ID " + kind_id)
		check(kind_id == COLLISION_IDS[index], "collision kind order is deterministic: " + kind_id)
		check(typeof(row.get("enabled", null)) == TYPE_BOOL and typeof(row.get("one_way", null)) == TYPE_BOOL,
			"collision flags are explicit: " + kind_id)


func _test_manifest_draw_layers() -> void:
	var draw_layers := _array_value(manifest.get("draw_layers", []))
	check(draw_layers.size() == DRAW_LAYER_IDS.size(), "manifest enumerates every draw layer")
	var previous_z := -1
	for index in range(min(draw_layers.size(), DRAW_LAYER_IDS.size())):
		var row := _dictionary_value(draw_layers[index])
		var layer_id := _string_value(row.get("id", ""))
		_check_stable_id(_string_value(row.get("stable_id", "")), &"draw", "draw-layer stable ID " + layer_id)
		_check_part(layer_id, "draw-layer short ID " + layer_id)
		check(layer_id == DRAW_LAYER_IDS[index], "draw-layer order is deterministic: " + layer_id)
		var z_index := int(row.get("z_index", -1))
		check(z_index > previous_z, "draw-layer z order increases: " + layer_id)
		previous_z = z_index
		check(typeof(row.get("y_sort", null)) == TYPE_BOOL and typeof(row.get("occludes", null)) == TYPE_BOOL,
			"draw-layer y-sort/occlusion flags are explicit: " + layer_id)


func _test_manifest_peering() -> void:
	var peering := _dictionary_value(manifest.get("terrain_peering", {}))
	var peering_order := _array_value(manifest.get("terrain_peering_order", []))
	check(PEERING_BITS.size() == 8 and PEERING_VALUES.size() == 8,
		"contract declares exactly eight valid square peering bits")
	check(PEERING_BITS == [0, 3, 4, 7, 8, 11, 12, 15],
		"Godot square peering constants are exactly the valid bit set")
	check(peering_order == PEERING_NAMES,
		"manifest peering order contains only valid Godot square positions")
	check(peering_order.size() == PEERING_BITS.size(),
		"manifest declares exactly the native valid peering positions")
	for terrain_id in TERRAIN_IDS:
		var values := _array_value(peering.get(terrain_id, []))
		check(values.size() == PEERING_BITS.size(), "terrain peering has one entry per valid native position: " + terrain_id)
		for value in values:
			check(TERRAIN_IDS.has(_string_value(value)), "terrain peering references a known terrain")


func _test_manifest_tiles() -> void:
	var tiles := _array_value(manifest.get("tiles", []))
	check(tiles.size() == 18, "manifest has sixteen base tiles and two alternatives")
	var base_coordinates: Dictionary = {}
	var tile_ids: Dictionary = {}
	var terrain_coverage: Dictionary = {}
	var navigation_coverage: Dictionary = {}
	var collision_coverage: Dictionary = {}
	var draw_coverage: Dictionary = {}
	for value in tiles:
		var row := _dictionary_value(value)
		var tile_id := _string_value(row.get("stable_id", ""))
		_check_stable_id(tile_id, &"tile", "tile stable ID")
		check(not tile_ids.has(tile_id), "tile stable IDs are unique: " + tile_id)
		tile_ids[tile_id] = true
		var coordinate := _array_value(row.get("atlas_coord", []))
		check(coordinate.size() == 2 and _integer_like(coordinate[0]) and _integer_like(coordinate[1]),
			"tile has an integer atlas coordinate: " + tile_id)
		if coordinate.size() != 2:
			continue
		var x := int(coordinate[0])
		var y := int(coordinate[1])
		check(x >= 0 and x < 4 and y >= 0 and y < 4, "tile coordinate is inside the 4x4 atlas: " + tile_id)
		var alternative_id := int(row.get("alternative_id", -1))
		check(_integer_like(row.get("alternative_id", null)) and alternative_id >= 0,
			"tile alternative ID is bounded: " + tile_id)
		if alternative_id == 0:
			var key := "%d,%d" % [x, y]
			check(not base_coordinates.has(key), "base atlas coordinates are unique: " + key)
			base_coordinates[key] = true
		check(int(row.get("frame_index", -1)) == y * 4 + x,
			"tile frame index derives from explicit row-major coordinates: " + tile_id)
		check(row.get("terrain_id", "") in TERRAIN_IDS, "tile terrain is enumerated: " + tile_id)
		check(row.get("navigation_kind", "") in NAVIGATION_IDS, "tile navigation is enumerated: " + tile_id)
		check(row.get("collision_kind", "") in COLLISION_IDS, "tile collision is enumerated: " + tile_id)
		check(row.get("draw_layer", "") in DRAW_LAYER_IDS, "tile draw layer is enumerated: " + tile_id)
		_check_stable_id(_string_value(row.get("terrain_stable_id", "")), &"terrain", "tile terrain stable ID")
		_check_stable_id(_string_value(row.get("navigation_stable_id", "")), &"navigation", "tile navigation stable ID")
		_check_stable_id(_string_value(row.get("collision_stable_id", "")), &"collision", "tile collision stable ID")
		_check_stable_id(_string_value(row.get("draw_stable_id", "")), &"draw", "tile draw stable ID")
		check(TERRAIN_IDS.has(_string_value(row.get("terrain_peering_id", ""))),
			"tile terrain peering ID is enumerated: " + tile_id)
		var navigation_polygon := _string_value(row.get("navigation_polygon", ""))
		check(navigation_polygon.is_empty() or navigation_polygon == "full_cell",
			"tile navigation polygon kind is explicit: " + tile_id)
		var collision_polygon := _string_value(row.get("collision_polygon", ""))
		check(collision_polygon.is_empty() or collision_polygon == "full_cell" or collision_polygon == "dock_edge",
			"tile collision polygon kind is explicit: " + tile_id)
		if row.get("collision_kind", "") == "one_way":
			check(collision_polygon == "dock_edge", "one-way tile uses the dock edge polygon: " + tile_id)
		check(_integer_like(row.get("z_index", null)) and _integer_like(row.get("y_sort_origin", null)),
			"tile draw z/y metadata is integer-valued: " + tile_id)
		check(typeof(row.get("occludes", null)) == TYPE_BOOL, "tile occlusion metadata is explicit: " + tile_id)
		terrain_coverage[_string_value(row.get("terrain_id", ""))] = true
		navigation_coverage[_string_value(row.get("navigation_kind", ""))] = true
		collision_coverage[_string_value(row.get("collision_kind", ""))] = true
		draw_coverage[_string_value(row.get("draw_layer", ""))] = true
	check(base_coordinates.size() == 16, "manifest covers every native 4x4 base coordinate")
	for y in range(4):
		for x in range(4):
			check(base_coordinates.has("%d,%d" % [x, y]), "base coordinate exists: %d,%d" % [x, y])
	check(terrain_coverage.size() == TERRAIN_IDS.size(), "tile catalog covers all terrains")
	check(navigation_coverage.size() == NAVIGATION_IDS.size(), "tile catalog covers all navigation kinds")
	check(collision_coverage.size() == COLLISION_IDS.size(), "tile catalog covers all collision kinds")
	check(draw_coverage.size() == DRAW_LAYER_IDS.size(), "tile catalog covers all draw layers")


func _test_registry_provenance() -> void:
	var registry: ZerkovAssetRegistry = ZerkovAssetRegistry.build_registry()
	check(registry.is_loaded() and registry.is_valid(), "curated asset registry remains valid")
	var asset := registry.get_asset(SOURCE_ASSET_ID)
	check(not asset.is_empty(), "greybox source resolves by exact registry ID")
	check(registry.resolve_alias(SOURCE_ALIAS).get("id", "") == SOURCE_ASSET_ID,
		"greybox source alias resolves without filename inference")
	check(asset.get("availability", "") == "imported", "greybox source is explicitly imported")
	check(asset.get("runtime_path", "") == ATLAS_PATH, "greybox source runtime path is exact")
	check(asset.get("runtime_sha256", "") == SOURCE_SHA256, "greybox runtime digest is exact")
	check(asset.get("family", "") == "project_owned" and asset.get("kind", "") == "atlas",
		"greybox source is a project-owned atlas registry row")
	var provenance := _dictionary_value(asset.get("provenance", {}))
	var manifest_provenance := _dictionary_value(manifest.get("provenance", {}))
	check(provenance.get("source_root", "") == "res://",
		"registry provenance root is stable across project checkouts")
	check(provenance.get("source_root", "") == manifest.get("source_root", ""), "registry source root matches manifest")
	check(provenance.get("source_relative_path", "") == manifest.get("source_relative_path", ""),
		"registry source-relative path matches manifest")
	check(provenance.get("source_status", "") == "available", "registry source status is available")
	check(provenance.get("source_sha256", "") == SOURCE_SHA256, "registry source digest is exact")
	check(manifest_provenance.is_empty(), "manifest keeps provenance fields top-level and explicit")
	var filtering := _dictionary_value(asset.get("filtering", {}))
	check(filtering.get("mode", "") == "nearest" and filtering.get("mipmaps", true) == false,
		"registry keeps nearest/no-mipmap filtering")
	var license := _dictionary_value(asset.get("license", {}))
	check(license.get("status", "") == "cleared" and license.get("name", "") == "MIT",
		"registry records a cleared MIT license")
	check(license.get("reference", "") == "licenses/zerkov-sawmill-greybox-MIT.txt",
		"registry license reference is project-relative")
	check(asset.get("semantic_manifest", "") == MANIFEST_PATH, "registry links the semantic manifest")
	var atlas := _dictionary_value(asset.get("atlas", {}))
	check(atlas.get("source_size", []) == [128, 128] and atlas.get("cell_size", []) == [32, 32],
		"registry atlas dimensions are exact")
	check(atlas.get("columns", 0) == 4 and atlas.get("rows", 0) == 4 and atlas.get("frame_count", 0) == 16,
		"registry atlas grid is exact")
	var external := registry.get_asset("zerkov.asset.world.exterior_textures")
	check(external.get("availability", "") == "pending_unimported",
		"pending external Exterior Textures row remains explicitly pending")
	check(asset.get("id", "") != external.get("id", ""), "greybox source never aliases the pending external row")


func _test_native_shape(tile_set: TileSet) -> void:
	check(tile_set.resource_name == "Sawmill Project-Owned Greybox TileSet", "native resource name is explicit")
	check(tile_set.get_tile_shape() == TileSet.TILE_SHAPE_SQUARE, "native TileSet uses square cells")
	check(tile_set.get_tile_layout() == TileSet.TILE_LAYOUT_STACKED, "native TileSet uses stacked atlas layout")
	check(tile_set.get_tile_size() == Vector2i(32, 32), "native TileSet cell size is exactly 32 px")
	check(tile_set.is_uv_clipping(), "native TileSet keeps UV clipping enabled")
	check(tile_set.get_physics_layers_count() == 1, "one native physics layer is authored")
	if tile_set.get_physics_layers_count() == 1:
		check(tile_set.get_physics_layer_collision_layer(0) == 1, "native collision layer uses bit one")
		check(tile_set.get_physics_layer_collision_mask(0) == 1, "native collision mask uses bit one")
		check(is_equal_approx(tile_set.get_physics_layer_collision_priority(0), 1.0), "native collision priority is one")
	check(tile_set.get_navigation_layers_count() == 1, "one native navigation layer is authored")
	if tile_set.get_navigation_layers_count() == 1:
		check(tile_set.get_navigation_layer_layers(0) == 1, "native navigation layer uses bit one")
	check(tile_set.get_occlusion_layers_count() == 1, "one native occlusion layer is authored")
	if tile_set.get_occlusion_layers_count() == 1:
		check(tile_set.get_occlusion_layer_light_mask(0) == 1, "native occlusion light mask uses bit one")
		check(not tile_set.get_occlusion_layer_sdf_collision(0), "native occlusion SDF flag is explicit")
	check(tile_set.get_terrain_sets_count() == 1, "one native terrain set is authored")
	if tile_set.get_terrain_sets_count() == 1:
		check(tile_set.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES,
			"native terrain mode matches the manifest")
		check(tile_set.get_terrains_count(0) == TERRAIN_IDS.size(), "native terrain count is complete")
		for index in range(TERRAIN_IDS.size()):
			check(tile_set.get_terrain_name(0, index) == TERRAIN_IDS[index], "native terrain name is stable")
	check(tile_set.get_custom_data_layers_count() == CUSTOM_DATA_NAMES.size(), "native custom-data layers are complete")
	for index in range(CUSTOM_DATA_NAMES.size()):
		check(tile_set.get_custom_data_layer_name(index) == CUSTOM_DATA_NAMES[index], "native custom-data layer name is stable")
		check(tile_set.get_custom_data_layer_type(index) == TYPE_STRING, "native custom-data layer type is String")
	check(tile_set.get_source_count() == 1, "native TileSet has one atlas source")
	if tile_set.get_source_count() != 1:
		return
	var source := tile_set.get_source(0) as TileSetAtlasSource
	check(source != null, "native source is TileSetAtlasSource")
	if source == null:
		return
	var texture := source.get_texture()
	check(texture != null, "native atlas texture is non-null")
	if texture != null:
		check(texture.resource_path == ATLAS_PATH, "native atlas texture path is project-owned SVG")
	check(source.get_texture_region_size() == Vector2i(32, 32), "native atlas region size is exactly 32 px")
	check(source.get_atlas_grid_size() == Vector2i(4, 4), "native atlas grid is four by four")
	check(source.get_tiles_count() == 16, "native atlas has sixteen actual base coordinates")
	check(not source.has_tiles_outside_texture(), "native atlas has no coordinates outside its texture")
	check(source.get_alternative_tiles_count(Vector2i(0, 0)) == 2, "dirt coordinate has an explicit alternative ID")
	check(source.get_alternative_tiles_count(Vector2i(0, 1)) == 2, "road coordinate has an explicit alternative ID")


func _test_native_tiles(tile_set: TileSet) -> void:
	if tile_set.get_source_count() != 1:
		return
	var source := tile_set.get_source(0) as TileSetAtlasSource
	if source == null:
		return
	var tiles := _array_value(manifest.get("tiles", []))
	var actual_base_coordinates: Dictionary = {}
	var native_alternatives := 0
	var native_navigation := 0
	var native_collision := 0
	var native_occlusion := 0
	var native_peering := 0
	for value in tiles:
		var row := _dictionary_value(value)
		var coordinate_array := _array_value(row.get("atlas_coord", []))
		if coordinate_array.size() != 2:
			continue
		var coordinate := Vector2i(int(coordinate_array[0]), int(coordinate_array[1]))
		var alternative_id := int(row.get("alternative_id", -1))
		check(source.has_tile(coordinate), "native tile coordinate exists: " + _string_value(row.get("stable_id", "")))
		check(source.has_alternative_tile(coordinate, alternative_id),
			"native alternative ID exists: " + _string_value(row.get("stable_id", "")))
		if alternative_id == 0:
			actual_base_coordinates[coordinate] = true
		else:
			native_alternatives += 1
		if not source.has_tile(coordinate) or not source.has_alternative_tile(coordinate, alternative_id):
			continue
		var data: TileData = source.get_tile_data(coordinate, alternative_id)
		check(data != null, "native TileData exists: " + _string_value(row.get("stable_id", "")))
		if data == null:
			continue
		var tile_id := _string_value(row.get("stable_id", ""))
		check(_string_value(data.get_custom_data("source_tile_id")) == tile_id, "TileData stable ID is consumable")
		check(_string_value(data.get_custom_data("navigation_kind")) == _string_value(row.get("navigation_kind", "")),
			"TileData navigation kind is consumable: " + tile_id)
		check(_string_value(data.get_custom_data("collision_kind")) == _string_value(row.get("collision_kind", "")),
			"TileData collision kind is consumable: " + tile_id)
		check(_string_value(data.get_custom_data("draw_layer")) == _string_value(row.get("draw_layer", "")),
			"TileData draw layer is consumable: " + tile_id)
		check(data.get_terrain_set() == 0, "TileData terrain set is native set zero: " + tile_id)
		var terrain_id := _string_value(row.get("terrain_id", ""))
		var terrain_index := TERRAIN_IDS.find(terrain_id)
		check(data.get_terrain() == terrain_index, "TileData terrain index is explicit: " + tile_id)
		var peering_values := _array_value(_dictionary_value(manifest.get("terrain_peering", {})).get(terrain_id, []))
		for index in range(PEERING_BITS.size()):
			var bit: int = PEERING_BITS[index]
			check(data.is_valid_terrain_peering_bit(bit), "TileData exposes the exact valid peering bit: " + tile_id)
			native_peering += 1
			var expected_id := _string_value(peering_values[index])
			check(data.get_terrain_peering_bit(bit) == TERRAIN_IDS.find(expected_id),
				"TileData terrain peering is explicit: " + tile_id)
		var expected_navigation := not _string_value(row.get("navigation_polygon", "")).is_empty()
		var navigation_polygon := data.get_navigation_polygon(0)
		check((navigation_polygon != null) == expected_navigation, "TileData navigation polygon matches manifest: " + tile_id)
		if navigation_polygon != null:
			native_navigation += 1
			check(navigation_polygon.get_polygon_count() > 0, "navigation polygon has a native polygon: " + tile_id)
		var expected_collision := not _string_value(row.get("collision_polygon", "")).is_empty()
		var collision_count := data.get_collision_polygons_count(0)
		check((collision_count > 0) == expected_collision, "TileData collision polygon matches manifest: " + tile_id)
		if collision_count > 0:
			native_collision += 1
			check(collision_count == 1, "TileData has one collision polygon: " + tile_id)
			check(data.is_collision_polygon_one_way(0, 0) == (row.get("collision_kind", "") == "one_way"),
				"collision one-way flag is explicit: " + tile_id)
		var occluder_count := data.get_occluder_polygons_count(0)
		check((occluder_count > 0) == bool(row.get("occludes", false)), "TileData occlusion matches draw metadata: " + tile_id)
		if occluder_count > 0:
			native_occlusion += 1
		check(data.get_z_index() == int(row.get("z_index", 0)), "TileData z index is explicit: " + tile_id)
		check(data.get_y_sort_origin() == int(row.get("y_sort_origin", 0)), "TileData y-sort origin is explicit: " + tile_id)
	check(actual_base_coordinates.size() == 16, "native source contains all sixteen base coordinates")
	check(native_alternatives == 2, "native source contains two explicit alternatives")
	check(native_navigation > 0, "native source contains navigation polygons")
	check(native_collision > 0, "native source contains collision polygons")
	check(native_occlusion > 0, "native source contains occluder polygons")
	check(native_peering > 0, "native source contains terrain peering data")


func _test_tilemap_polygon_bounds(tile_set: TileSet) -> void:
	var layer := TileMapLayer.new()
	layer.set_tile_set(tile_set)
	var tiles := _array_value(manifest.get("tiles", []))
	var navigation_count := 0
	var collision_count := 0
	var occluder_count := 0
	for index in range(tiles.size()):
		var row := _dictionary_value(tiles[index])
		var coordinate_array := _array_value(row.get("atlas_coord", []))
		if coordinate_array.size() != 2:
			continue
		var coordinate := Vector2i(int(coordinate_array[0]), int(coordinate_array[1]))
		var alternative_id := int(row.get("alternative_id", -1))
		var cell := Vector2i(index, 0)
		layer.set_cell(cell, 0, coordinate, alternative_id)
		var cell_center := layer.map_to_local(cell)
		var expected_center := Vector2(cell.x * 32 + 16, cell.y * 32 + 16)
		check(cell_center == expected_center, "TileMapLayer map_to_local returns the centered 32 px cell origin")
		var data: TileData = layer.get_cell_tile_data(cell)
		check(data != null, "TileMapLayer exposes mapped native TileData")
		if data == null:
			continue
		var tile_id := _string_value(row.get("stable_id", ""))
		var navigation_expected := not _string_value(row.get("navigation_polygon", "")).is_empty()
		if navigation_expected:
			navigation_count += 1
			var navigation_polygon := data.get_navigation_polygon(0)
			check(navigation_polygon != null, "mapped TileData keeps the navigation polygon: " + tile_id)
			if navigation_polygon != null:
				var navigation_points := _translated_points(cell_center, navigation_polygon.get_vertices())
				check(_rect_approx(_points_bounds(navigation_points), _cell_rect(cell)),
					"mapped navigation polygon bounds equal its world cell: " + tile_id)
		var collision_polygon_kind := _string_value(row.get("collision_polygon", ""))
		if not collision_polygon_kind.is_empty():
			collision_count += 1
			var native_collision_count := data.get_collision_polygons_count(0)
			check(native_collision_count == 1, "mapped TileData keeps one collision polygon: " + tile_id)
			if native_collision_count > 0:
				var collision_points := _translated_points(cell_center, data.get_collision_polygon_points(0, 0))
				var expected_collision_rect := _cell_rect(cell)
				if collision_polygon_kind == "dock_edge":
					expected_collision_rect = Rect2(Vector2(cell.x * 32, cell.y * 32 + 24), Vector2(32, 8))
				check(_rect_approx(_points_bounds(collision_points), expected_collision_rect),
					"mapped collision polygon bounds equal its authored world shape: " + tile_id)
		var occludes := bool(row.get("occludes", false))
		if occludes:
			occluder_count += 1
			var native_occluder_count := data.get_occluder_polygons_count(0)
			check(native_occluder_count == 1, "mapped TileData keeps one occluder polygon: " + tile_id)
			if native_occluder_count > 0:
				var occluder := data.get_occluder(0, 0)
				check(occluder != null, "mapped TileData exposes its occluder polygon: " + tile_id)
				if occluder != null:
					var occluder_points := _translated_points(cell_center, occluder.get_polygon())
					check(_rect_approx(_points_bounds(occluder_points), _cell_rect(cell)),
						"mapped occluder polygon bounds equal its world cell: " + tile_id)
	check(navigation_count == 11, "TileMapLayer validates all eleven navigation polygons")
	check(collision_count == 6, "TileMapLayer validates all six collision polygons")
	check(occluder_count == 4, "TileMapLayer validates all four occluder polygons")


func _translated_points(origin: Vector2, points: PackedVector2Array) -> PackedVector2Array:
	var translated := PackedVector2Array()
	for point in points:
		translated.append(origin + point)
	return translated


func _points_bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum.x = min(minimum.x, point.x)
		minimum.y = min(minimum.y, point.y)
		maximum.x = max(maximum.x, point.x)
		maximum.y = max(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(Vector2(cell.x * 32, cell.y * 32), Vector2(32, 32))


func _rect_approx(actual: Rect2, expected: Rect2) -> bool:
	return actual.position.is_equal_approx(expected.position) and actual.size.is_equal_approx(expected.size)


func _test_metadata(tile_set: TileSet) -> void:
	check(tile_set.get_meta("sawmill_schema_version", 0) == 1, "TileSet metadata schema is explicit")
	check(tile_set.get_meta("sawmill_source_asset_id", "") == SOURCE_ASSET_ID, "TileSet metadata source ID is exact")
	check(tile_set.get_meta("sawmill_source_asset_alias", "") == SOURCE_ALIAS, "TileSet metadata source alias is exact")
	check(tile_set.get_meta("sawmill_source_registry_id", "") == "zerkov.assets", "TileSet metadata registry namespace is exact")
	check(tile_set.get_meta("sawmill_source_registry_path", "") == REGISTRY_PATH, "TileSet metadata registry path is exact")
	check(tile_set.get_meta("sawmill_semantic_manifest_path", "") == MANIFEST_PATH, "TileSet metadata manifest path is exact")
	var provenance := _dictionary_value(tile_set.get_meta("sawmill_source_provenance", {}))
	for key in ["source_root", "source_relative_path", "source_status", "source_sha256", "runtime_path", "runtime_sha256"]:
		check(provenance.get(key, null) == manifest.get(key, null), "TileSet provenance matches manifest: " + key)
	check(provenance.get("filtering", "") == "nearest" and provenance.get("mipmaps", true) == false,
		"TileSet provenance records nearest/no-mipmap policy")
	check(_canonical_json(tile_set.get_meta("sawmill_source_license", {})) == _canonical_json(manifest.get("license", {})),
		"TileSet metadata carries explicit license provenance")
	var atlas_expected := {
		"source_size": manifest.get("source_size_px", []),
		"cell_size": manifest.get("tile_size_px", []),
		"columns": manifest.get("columns", 0),
		"rows": manifest.get("rows", 0),
		"frame_count": manifest.get("frame_count", 0),
	}
	check(_canonical_json(tile_set.get_meta("sawmill_source_atlas", {})) == _canonical_json(atlas_expected),
		"TileSet metadata carries explicit atlas dimensions")
	for pair in [
		["sawmill_terrain_metadata", "terrain_set"],
		["sawmill_terrain_peering", "terrain_peering"],
		["sawmill_navigation_metadata", "navigation"],
		["sawmill_collision_metadata", "collision"],
		["sawmill_draw_layer_metadata", "draw_layers"],
		["sawmill_tile_catalog", "tiles"],
		["sawmill_authoring", "authoring"],
	]:
		check(_canonical_json(tile_set.get_meta(pair[0], null)) == _canonical_json(manifest.get(pair[1], null)),
			"TileSet metadata matches semantic manifest: " + pair[0])


func _test_repair_probes(canonical: TileSet) -> void:
	check(_collect_native_findings(canonical).is_empty(), "repaired TileSet has no native contract findings")
	var texture := ResourceLoader.load(ATLAS_PATH, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	var blank := TileSet.new()
	blank.set_tile_size(Vector2i(32, 32))
	var blank_source := TileSetAtlasSource.new()
	blank_source.set_texture(texture)
	blank_source.set_texture_region_size(Vector2i(32, 32))
	blank.add_source(blank_source, 0)
	check(_collect_native_findings(blank).has("native_coordinates"),
		"fail-before probe rejects an atlas with zero native coordinates")

	var missing_tile := canonical.duplicate(true) as TileSet
	if missing_tile != null and missing_tile.get_source_count() == 1:
		var missing_source := missing_tile.get_source(0) as TileSetAtlasSource
		if missing_source != null:
			missing_source.remove_tile(Vector2i(0, 0))
	check(_collect_native_findings(missing_tile).has("tile_data"),
		"fail-before probe rejects missing native TileData")

	var missing_navigation := canonical.duplicate(true) as TileSet
	if missing_navigation != null and missing_navigation.get_navigation_layers_count() > 0:
		missing_navigation.remove_navigation_layer(0)
	check(_collect_native_findings(missing_navigation).has("navigation_layer"),
		"fail-before probe rejects missing navigation layer data")

	var missing_collision := canonical.duplicate(true) as TileSet
	if missing_collision != null and missing_collision.get_physics_layers_count() > 0:
		missing_collision.remove_physics_layer(0)
	check(_collect_native_findings(missing_collision).has("collision_layer"),
		"fail-before probe rejects missing collision layer data")

	var missing_terrain := canonical.duplicate(true) as TileSet
	if missing_terrain != null and missing_terrain.get_terrain_sets_count() > 0:
		missing_terrain.remove_terrain_set(0)
	check(_collect_native_findings(missing_terrain).has("terrain_set"),
		"fail-before probe rejects missing terrain data")

	var missing_custom := canonical.duplicate(true) as TileSet
	if missing_custom != null:
		while missing_custom.get_custom_data_layers_count() > 0:
			missing_custom.remove_custom_data_layer(missing_custom.get_custom_data_layers_count() - 1)
	check(_collect_native_findings(missing_custom).has("custom_data"),
		"fail-before probe rejects missing per-tile custom data layers")


func _collect_native_findings(candidate: TileSet) -> Array[String]:
	var findings: Array[String] = []
	if candidate == null:
		_append_finding(findings, "native_coordinates")
		_append_finding(findings, "tile_data")
		return findings
	if candidate.get_tile_size() != Vector2i(32, 32):
		_append_finding(findings, "tile_data")
	if candidate.get_physics_layers_count() < 1:
		_append_finding(findings, "collision_layer")
	if candidate.get_navigation_layers_count() < 1:
		_append_finding(findings, "navigation_layer")
	if candidate.get_terrain_sets_count() < 1:
		_append_finding(findings, "terrain_set")
	if candidate.get_custom_data_layers_count() < CUSTOM_DATA_NAMES.size():
		_append_finding(findings, "custom_data")
	if candidate.get_source_count() < 1:
		_append_finding(findings, "native_coordinates")
		_append_finding(findings, "tile_data")
		return findings
	var source := candidate.get_source(0) as TileSetAtlasSource
	if source == null or source.get_texture() == null:
		_append_finding(findings, "native_coordinates")
		_append_finding(findings, "tile_data")
		return findings
	if source.get_tiles_count() <= 0:
		_append_finding(findings, "native_coordinates")
	var tiles := _array_value(manifest.get("tiles", []))
	for value in tiles:
		var row := _dictionary_value(value)
		var coordinate_array := _array_value(row.get("atlas_coord", []))
		if coordinate_array.size() != 2:
			_append_finding(findings, "native_coordinates")
			continue
		var coordinate := Vector2i(int(coordinate_array[0]), int(coordinate_array[1]))
		var alternative_id := int(row.get("alternative_id", -1))
		if not source.has_tile(coordinate) or not source.has_alternative_tile(coordinate, alternative_id):
			_append_finding(findings, "native_coordinates")
			_append_finding(findings, "tile_data")
			continue
		var data: TileData = source.get_tile_data(coordinate, alternative_id)
		if data == null:
			_append_finding(findings, "tile_data")
			continue
		if candidate.get_terrain_sets_count() < 1 or data.get_terrain_set() < 0 or data.get_terrain() < 0:
			_append_finding(findings, "terrain_set")
		if candidate.get_navigation_layers_count() < 1:
			_append_finding(findings, "navigation_layer")
		if candidate.get_physics_layers_count() < 1:
			_append_finding(findings, "collision_layer")
		if candidate.get_custom_data_layers_count() >= CUSTOM_DATA_NAMES.size():
			for custom_name in CUSTOM_DATA_NAMES:
				if _string_value(data.get_custom_data(custom_name)).is_empty():
					_append_finding(findings, "custom_data")
	return findings


func _append_finding(findings: Array[String], value: String) -> void:
	if not findings.has(value):
		findings.append(value)


func _metadata_signature(tile_set: TileSet) -> String:
	var keys := [
		"sawmill_schema_version",
		"sawmill_source_asset_id",
		"sawmill_source_asset_alias",
		"sawmill_source_registry_id",
		"sawmill_source_registry_path",
		"sawmill_semantic_manifest_path",
		"sawmill_source_provenance",
		"sawmill_source_license",
		"sawmill_source_atlas",
		"sawmill_terrain_metadata",
		"sawmill_terrain_peering",
		"sawmill_navigation_metadata",
		"sawmill_collision_metadata",
		"sawmill_draw_layer_metadata",
		"sawmill_tile_catalog",
		"sawmill_authoring",
	]
	var encoded := PackedStringArray()
	for key in keys:
		encoded.append(_canonical_json(tile_set.get_meta(key, null)))
	return _sha256_text("|".join(encoded))


func _native_signature(tile_set: TileSet) -> String:
	var root: Dictionary = {
		"tile_size": _vector2i_to_array(tile_set.get_tile_size()),
		"source_count": tile_set.get_source_count(),
	}
	var source_rows: Array = []
	for source_index in range(tile_set.get_source_count()):
		var source_id := tile_set.get_source_id(source_index)
		var source := tile_set.get_source(source_id)
		var source_row: Dictionary = {"id": source_id, "type": source.get_class()}
		if source is TileSetAtlasSource:
			var atlas := source as TileSetAtlasSource
			source_row["texture"] = atlas.get_texture().resource_path if atlas.get_texture() != null else ""
			source_row["region"] = _vector2i_to_array(atlas.get_texture_region_size())
			var tiles: Array = []
			for tile_index in range(atlas.get_tiles_count()):
				var coordinate := atlas.get_tile_id(tile_index)
				var alternatives: Array = []
				for alternative_index in range(atlas.get_alternative_tiles_count(coordinate)):
					var alternative_id := atlas.get_alternative_tile_id(coordinate, alternative_index)
					var data: TileData = atlas.get_tile_data(coordinate, alternative_id)
					var tile_row: Dictionary = {
						"coord": _vector2i_to_array(coordinate),
						"alternative": alternative_id,
					}
					if data != null:
						tile_row["terrain_set"] = data.get_terrain_set()
						tile_row["terrain"] = data.get_terrain()
						var peering: Array = []
						for bit in PEERING_BITS:
							peering.append([bit, data.get_terrain_peering_bit(bit)])
						tile_row["peering"] = peering
						for custom_name in CUSTOM_DATA_NAMES:
							tile_row["custom_" + custom_name] = _string_value(data.get_custom_data(custom_name))
						tile_row["z"] = data.get_z_index()
						tile_row["y"] = data.get_y_sort_origin()
						var navigation_polygon := data.get_navigation_polygon(0)
						tile_row["navigation"] = _navigation_signature(navigation_polygon)
						var collision: Array = []
						for polygon_index in range(data.get_collision_polygons_count(0)):
							collision.append({
								"points": _packed_vector2_to_array(data.get_collision_polygon_points(0, polygon_index)),
								"one_way": data.is_collision_polygon_one_way(0, polygon_index),
							})
						tile_row["collision"] = collision
						tile_row["occluders"] = data.get_occluder_polygons_count(0)
					alternatives.append(tile_row)
				tiles.append(alternatives)
			source_row["tiles"] = tiles
		source_rows.append(source_row)
	root["sources"] = source_rows
	return _sha256_text(_canonical_json(root))


func _navigation_signature(polygon: NavigationPolygon) -> Dictionary:
	if polygon == null:
		return {"vertices": [], "polygons": []}
	var polygons: Array = []
	for index in range(polygon.get_polygon_count()):
		polygons.append(_packed_int_to_array(polygon.get_polygon(index)))
	return {"vertices": _packed_vector2_to_array(polygon.get_vertices()), "polygons": polygons}


func _check_stable_id(value: String, expected_kind: StringName, label: String) -> void:
	check(IDENTITY_RULES.is_valid(value, expected_kind), label + " uses bounded Zerkov grammar: " + value)


func _check_part(value: String, label: String) -> void:
	check(IDENTITY_RULES.is_valid_part(value), label + " uses bounded lowercase grammar: " + value)


func _dictionary_value(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	return {}


func _array_value(value: Variant) -> Array:
	if value is Array:
		return value as Array
	return []


func _integer_pair_equals(value: Variant, expected: Vector2i) -> bool:
	var pair := _array_value(value)
	return pair.size() == 2 and _integer_like(pair[0]) and _integer_like(pair[1]) \
		and int(pair[0]) == expected.x and int(pair[1]) == expected.y


func _string_value(value: Variant) -> String:
	if value is String:
		return value
	return ""


func _integer_like(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return is_finite(number) and number == floor(number)


func _vector2i_to_array(value: Vector2i) -> Array:
	return [value.x, value.y]


func _packed_vector2_to_array(value: PackedVector2Array) -> Array:
	var result: Array = []
	for point in value:
		result.append([point.x, point.y])
	return result


func _packed_int_to_array(value: PackedInt32Array) -> Array:
	var result: Array = []
	for number in value:
		result.append(number)
	return result


func _full_cell() -> PackedVector2Array:
	return PackedVector2Array([Vector2(-16, -16), Vector2(16, -16), Vector2(16, 16), Vector2(-16, 16)])


func _dock_edge() -> PackedVector2Array:
	return PackedVector2Array([Vector2(-16, 8), Vector2(16, 8), Vector2(16, 16), Vector2(-16, 16)])


func _canonical_json(value: Variant) -> String:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var keys := PackedStringArray()
		for key in dictionary.keys():
			keys.append(_string_value(key) if key is String else str(key))
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
	if value is PackedStringArray:
		var strings := PackedStringArray()
		for item in value:
			strings.append(JSON.stringify(item))
		return "[" + ",".join(strings) + "]"
	return JSON.stringify(value)


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _sha256_text(value: String) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(value.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


func _print_result() -> void:
	print("SAWMILL_TILESET_RESULT checks=", checks, " failures=", failures,
		" tiles=16 alternatives=2 cache_mode=ignore source_asset=", SOURCE_ASSET_ID,
		" source_status=available")
