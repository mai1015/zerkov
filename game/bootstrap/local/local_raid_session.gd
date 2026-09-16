class_name LocalRaidSession
extends Node2D
## Product composition: persisted loadout -> existing movement/AI/combat/task
## owners -> committed settlement. UI receives only LocalGameUI/projections.
var last_error: StringName = &""
var deployment: RaidDeployment
var raid: RaidAuthority
var combat: RaidCombatSession
var progression: RaidProgression
var interaction: ZInteractionPolicyOwner
var movement_world: ZMovementWorld2D
var layout: ZSawmillYardLayout
var player_movement: ZPlayerLocomotion
var player_input: RaidGameplayInput
var player_router: ZCombatActionRouter
var hud_model: ZCombatHudModel
var ai: RaidAIRuntime
var camera := ZWorldCamera2D.new()
var crate_ids: Dictionary = {}
var rows: Dictionary = {}
var _routers: Dictionary = {}
var _inventory_owners: Array[RaidInventoryOwner] = []
var _vision: RaidVisionWorldOwner
var _ai_driver: RaidAIPhaseDriver
var _ai_port: LocalRaidAIWorldPort
var _actors: Dictionary = {}
var _navigation: ZNavigationPathService
var _generation: int = 0
var _ai_released: bool = false
var _released: bool = false
var _started: bool = false
var _inside: bool = false
var _closing: bool = false
var _world_scene: Node2D

func start(store: ProfileStore, request_id: String, profile_generation: int, seed: int) -> bool:
	if _started or not is_inside_tree(): return _fail(&"local_raid_already_started")
	_started = true
	deployment = RaidDeployment.new()
	if not deployment.begin(self, store, request_id, profile_generation, seed): return _fail(deployment.last_error)
	raid = deployment.raid
	_generation = raid.generation()
	_inventory_owners.append(deployment.inventory)
	layout = load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	if layout == null: return _fail(&"local_sawmill_missing")
	movement_world = ZMovementWorldBuilder.build_from_sawmill_layout(layout, _generation)
	if movement_world == null: return _fail(ZMovementWorldBuilder.last_error)
	var nav := ZNavigationGrid.bake_from_movement_world(movement_world, layout.size_cells, layout.revision, layout.level_id)
	_navigation = ZNavigationPathService.new()
	if nav == null or not _navigation.configure(nav, layout.revision): return _fail(&"local_navigation_failed")
	var targets := ZInteractionTargetIndex.build_from_sawmill_layout(layout)
	var bake := ZOccluderBake.bake(layout.structures, layout.size_cells)
	if not targets.ok or not bake.ok: return _fail(&"local_world_data_invalid")
	interaction = ZInteractionPolicyOwner.new()
	if not interaction.configure(_generation, targets.targets, bake.segments) \
		or not interaction.attach_movement_world(movement_world, _generation) \
		or not interaction.register_with_authority(raid, _generation): return _fail(interaction.last_error)
	if not _add_actor(raid.admission().actor_id, "player", "zerkov.spawn.sawmill.west_service", deployment.inventory): return false
	for archetype: String in ["scav", "mutant"]:
		var id := ZEntityId.from_parts(PackedStringArray(["local", archetype]))
		if not raid.authorize_actor(id, ZRaidIntent.Source.AI, _generation): return _fail(raid.last_error)
		var inventory: RaidInventoryOwner
		if archetype == "scav":
			inventory = RaidInventoryOwner.new()
			add_child(inventory)
			_inventory_owners.append(inventory)
			if not inventory.configure() or not LocalCampaignContent.equip_starter(inventory): return _fail(&"local_scav_inventory_failed")
		var anchor := "zerkov.encounter.sawmill.scav_cover" if archetype == "scav" else "zerkov.encounter.sawmill.mutant_verge"
		if not _add_actor(id, archetype, anchor, inventory): return false
	combat = RaidCombatSession.new()
	add_child(combat)
	var roster: Array[Dictionary] = []
	for row: Dictionary in rows.values(): roster.append(row)
	if not combat.start(raid, roster, _obstructions()): return _fail(combat.last_error)
	if not _create_crates(): return false
	progression = RaidProgression.new()
	if not progression.bind(raid, deployment.inventory, combat, interaction, crate_ids,
		LocalCampaignContent.RAID_LIMIT_TICKS, LocalCampaignContent.EXTRACTION_TICKS, player_movement):
		return _fail(progression.last_error)
	for key: String in rows:
		var encoder: ZCombatInputAdapter = RaidGameplayInput.new() if rows[key].archetype == "player" else ZCombatInputAdapter.new()
		var admission := raid.admission()
		if not encoder.configure_source(admission.session_id, rows[key].actor_id, admission.authority_epoch,
			_generation, rows[key].source): return _fail(&"local_encoder_failed")
		var sink := RaidCombatIntentSink.new()
		if not sink.bind(raid, rows[key].actor_id, rows[key].source, _generation): return _fail(&"local_intent_sink_failed")
		var router := ZCombatActionRouter.new()
		if not router.bind(encoder, sink): return _fail(router.last_error)
		if rows[key].archetype == "player":
			player_input = encoder as RaidGameplayInput
			player_router = router
		else: _routers[key] = router
	var scav := load("res://game/ai/profiles/scav.tres") as ZAIProfile
	var mutant := load("res://game/ai/profiles/mutant.tres") as ZAIProfile
	var registry := RaidVisionActorRegistry.new()
	if not registry.configure(_generation, scav, mutant): return _fail(registry.last_error)
	_vision = RaidVisionWorldOwner.new()
	add_child(_vision)
	var world_id: int = 1 + int(raid.raid_id().canonical_key().sha256_text().substr(0, 7).hex_to_int())
	if not _vision.configure(world_id, {}, registry, _generation) or not _vision.register_with_raid_authority(raid):
		return _fail(_vision.last_error)
	var segments: Array = []
	for index in range(bake.segments.size()):
		var segment: ZerkovOccluderSegment = bake.segments[index]
		segments.append({"id":index + 1,"a":ZAIValues.encode_point(segment.a),
			"b":ZAIValues.encode_point(segment.b),"mask":segment.mask,"two_sided":true})
	_ai_port = LocalRaidAIWorldPort.new()
	if not _ai_port.configure(raid, combat, rows, _routers, _navigation, layout.revision, segments): return _fail(&"local_ai_port_failed")
	ai = RaidAIRuntime.new()
	if not ai.configure(raid.raid_id().canonical_key(), _generation, seed, _ai_port, registry, scav, mutant): return _fail(ai.last_error)
	_ai_driver = RaidAIPhaseDriver.new()
	if not _ai_driver.bind(raid, _generation, ai, RaidCombatSession.PUBLISHER, 300,
		PackedStringArray(), 300): return _fail(_ai_driver.last_error)
	hud_model = ZCombatHudModel.new()
	if not hud_model.configure(raid.admission().actor_id.canonical_key(), _generation): return _fail(&"local_hud_binding_failed")
	if not _build_visuals(): return false
	if not raid.transition(RaidAuthority.Lifecycle.ACTIVE, _generation): return _fail(raid.last_error)
	return advance()

func advance() -> bool:
	if _inside or _released or _closing or raid == null or raid.lifecycle not in [RaidAuthority.Lifecycle.ACTIVE, RaidAuthority.Lifecycle.EXTRACTING]:
		return _fail(&"local_raid_tick_closed")
	_inside = true
	var ok := raid.advance_one(_generation)
	if ok: ok = progression.after_tick()
	_inside = false
	if not ok: return _fail(raid.last_error if not raid.last_error.is_empty() else progression.last_error)
	var frame := combat.execution.frame_for(raid.admission().actor_id.canonical_key())
	if not hud_model.publish(frame): return _fail(&"local_hud_frame_invalid")
	camera.follow_locomotion(player_movement)
	for key: String in _actors:
		var row: Dictionary = rows[key]
		if not _actors[key].present(row.movement.position_px, row.movement.velocity_px,
			row.movement.facing_direction, combat.execution.frame_for(key)):
			return _fail(&"local_actor_presentation_failed")
	return true

func nearest_target() -> String:
	if raid == null or _released: return ""
	var candidates: Array[String] = SupplyRunGraph.CRATES.duplicate()
	candidates.append(SupplyRunGraph.ROAD_GATE)
	var selected: String = ""
	var distance: float = INF
	for key: String in candidates:
		var kind: StringName = ZInteractionKind.EXTRACTION_ZONE if key == SupplyRunGraph.ROAD_GATE else ZInteractionKind.CRATE
		var result := interaction.evaluate_for_actor(raid.admission().actor_id, StringName(key), kind, _generation)
		if not result.allowed: continue
		var d := player_movement.position_px.distance_squared_to(layout.cell_center(layout.anchor(key).cell))
		if d < distance: distance = d; selected = key
	return selected

func interact(target: String) -> bool:
	if _released or target.is_empty() or target != nearest_target(): return false
	var intent := player_input.build_progression_intent(raid.last_processed_tick + 1, &"interaction", {"target_id":target})
	return intent != null and raid.enqueue_intent(intent, _generation)

func cancel_interaction() -> bool:
	if _released or raid == null: return false
	var intent := player_input.build_progression_intent(raid.last_processed_tick + 1, &"raid_cancel", {})
	return intent != null and raid.enqueue_intent(intent, _generation)

func finish() -> Dictionary:
	if _inside or raid == null or raid.lifecycle not in [RaidAuthority.Lifecycle.SETTLING, RaidAuthority.Lifecycle.COMPLETED]:
		return RaidProgressionValues.failure(&"local_settlement_not_ready")
	if not _release_ai(): return RaidProgressionValues.failure(last_error)
	return progression.finish(deployment.settlement)

func release() -> bool:
	if _inside: return _fail(&"local_release_during_tick")
	if _released: return true
	_closing = true
	if not _release_ai(): return false
	if progression != null and not progression.release(): return _fail(progression.last_error)
	if combat != null and not combat.release(): return _fail(combat.last_error)
	if player_router != null: player_router.release()
	for router: ZCombatActionRouter in _routers.values(): router.release()
	if hud_model != null: hud_model.release()
	for presenter: LocalActorPresenter in _actors.values(): presenter.release()
	if raid != null and raid.lifecycle in [RaidAuthority.Lifecycle.ACTIVE, RaidAuthority.Lifecycle.EXTRACTING, RaidAuthority.Lifecycle.PREPARING]:
		if not raid.transition(RaidAuthority.Lifecycle.FAILED, _generation): return _fail(raid.last_error)
	# Authority owns the reserved Vision slot, including SETTLING shutdown.
	# Release other consumers first, then let authority revoke Vision atomically.
	# Direct owner teardown is deliberately forbidden while settlement is pending.
	if raid != null and not raid.teardown(_generation): return _fail(raid.last_error)
	if _vision != null and _vision.generation() > 0 and _vision.lifecycle != RaidVisionWorldOwner.Lifecycle.TORN_DOWN \
		and not _vision.teardown(_vision.generation()): return _fail(_vision.last_error)
	for owner: RaidInventoryOwner in _inventory_owners:
		if owner.is_current_generation(owner.generation()) and not owner.teardown(owner.generation()): return _fail(&"local_inventory_release_failed")
	_released = true
	return true

func _release_ai() -> bool:
	if _ai_released: return true
	if _ai_driver != null and _ai_driver._generation != 0 and not _ai_driver.release(_generation): return _fail(_ai_driver.last_error)
	if _ai_port != null: _ai_port.release()
	_ai_released = true
	return true

func _add_actor(id: ZEntityId, archetype: String, anchor_id: String, owner: RaidInventoryOwner) -> bool:
	var anchor := layout.anchor(anchor_id)
	if anchor.is_empty(): return _fail(&"local_spawn_anchor_missing")
	var move := ZPlayerLocomotion.new()
	var source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER if archetype == "player" else ZRaidIntent.Source.AI
	var handler := StringName("local_move_" + archetype)
	move.configure(id, layout.cell_center(anchor.approach_cell), ZPlayerFacing.Facing4.EAST, source, handler)
	if not move.attach_movement_world(movement_world) or not move.register_with_authority(raid, _generation): return _fail(move.last_error)
	var point := ZWorldUnits.godot_to_canonical(move.position_px).vector2i_value
	rows[id.canonical_key()] = {"actor_id":id,"source":int(source),"movement":move,"movement_handler":handler,
		"inventory":owner,"natural_melee":archetype == "mutant", "archetype":archetype,
		"patrol":[point],"cover":[point]}
	if archetype == "player": player_movement = move
	return true

func _create_crates() -> bool:
	var owner := deployment.inventory
	var native := owner.raid_authority()
	for index in range(3):
		var id: int = owner.world_crate_inventory_id if index == 0 else native.create_inventory(String(ZerkovInventoryCatalog.PROFILE_WORLD_CRATE))
		if id < 1: return _fail(&"local_crate_creation_failed")
		crate_ids[SupplyRunGraph.CRATES[index]] = id
		var container: int = native.snapshot(id).get_containers()[0].id
		var contents: Array = [[ZerkovInventoryCatalog.ITEM_AMMO_762, 60, 3, 0], [ZerkovInventoryCatalog.ITEM_BANDAGE, 2, 4, 0]]
		if index == 0:
			contents.append([ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE, 1, 0, 0])
			contents.append([ZerkovInventoryCatalog.ITEM_AKM, 1, 0, 2])
			contents.append([ZerkovInventoryCatalog.ITEM_MACHETE, 1, 0, 4])
		for row: Array in contents:
			if native.insert_item(id, String(row[0]), row[1], {"kind":"spatial","container":container,
				"x":row[2],"y":row[3],"rotated":false}, LocalCampaignContent.CONTENT_ACTOR).get("accepted") != true:
				return _fail(&"local_crate_content_failed")
	return true

func _obstructions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for structure: Dictionary in layout.structures:
		if structure.layer != "Obstacles": continue
		var rect: Rect2i = structure.rect
		var minimum := ZWorldUnits.godot_to_canonical(Vector2(rect.position) * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT)
		var maximum := ZWorldUnits.godot_to_canonical(Vector2(rect.end) * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT)
		var id := ZObstructionId.from_parts(PackedStringArray(["sawmill", String(structure.id).sha256_text().substr(0, 24)]))
		result.append({"obstruction_id":id.canonical_key(),"geometry_revision":layout.revision,
			"min_raw":minimum.vector2i_value,"max_raw":maximum.vector2i_value,"collision_layer":2,"enabled":true})
	return result

func _build_visuals() -> bool:
	_world_scene = load("res://game/world/sawmill/sawmill_yard.tscn").instantiate() as Node2D
	add_child(_world_scene)
	add_child(camera)
	camera.configure(layout.world_bounds(), player_movement.position_px)
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://game/content/art/local_player_manifest.json"))
	if not value is Dictionary: return _fail(&"local_player_art_manifest_missing")
	var manifest: Dictionary = value
	var textures: Dictionary = {}
	for key: String in manifest.sources:
		var source: Dictionary = manifest.sources[key]
		if FileAccess.get_sha256(source.path) != source.sha256: return _fail(&"local_player_art_hash_mismatch")
		var texture := load(source.path) as Texture2D
		if texture == null: return _fail(&"local_player_texture_missing")
		textures[key] = texture
	for key: String in rows:
		var presenter := LocalActorPresenter.new()
		add_child(presenter)
		if not presenter.configure(manifest, textures, _generation): return _fail(&"local_player_art_bind_failed")
		presenter.modulate = Color.WHITE if rows[key].archetype == "player" else (Color(0.85,0.57,0.50) if rows[key].archetype == "scav" else Color(0.68,0.83,0.57))
		_actors[key] = presenter
	return true

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
