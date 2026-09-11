class_name ZUIFixtureProvider
extends RefCounted

## Explicit developer/test owner for the authored UI fixture document.
##
## Production route contexts never receive this provider.  A context captures
## one provider generation; replacing or releasing the provider detaches the
## old Dictionary before a later fixture session can begin, so a retained
## screen cannot write into the replacement session through a stale reference.

const FrontflowFixture = preload("res://ui/dev/fixtures/frontflow_fixture.gd")
const BunkerFixture = preload("res://ui/dev/fixtures/bunker_fixture.gd")
const InventoryFixture = preload("res://ui/dev/fixtures/inventory_fixture.gd")
const UtilityFixture = preload("res://ui/dev/fixtures/utility_fixture.gd")

var last_error: StringName = &""

var _active: bool = false
var _generation: int = 0
var _store: ZUIFixtureStore


func start(p_generation: int = 1) -> bool:
	last_error = &""
	if _active or p_generation <= _generation:
		return _reject(&"fixture_provider_start_invalid")
	_generation = p_generation
	_store = ZUIFixtureStore.new()
	_active = true
	return true


func is_active() -> bool:
	return _active


func generation() -> int:
	return _generation


func is_current(expected_generation: int) -> bool:
	return _active and expected_generation > 0 \
			and expected_generation == _generation and _store != null


func state(expected_generation: int) -> Variant:
	last_error = &""
	if not is_current(expected_generation):
		last_error = &"fixture_provider_stale_generation" \
				if _active else &"fixture_provider_released"
		return null
	return _store.state


func replace(expected_generation: int, next_generation: int) -> bool:
	last_error = &""
	if not is_current(expected_generation) or next_generation <= _generation:
		return _reject(&"fixture_provider_replace_invalid")
	# Detach the former document. References retained by stale test/developer
	# screens can mutate only the retired Dictionary, never this replacement.
	_store = ZUIFixtureStore.new()
	_generation = next_generation
	return true


func prepare_route(route: String, expected_generation: int) -> bool:
	var value: Variant = state(expected_generation)
	if not value is Dictionary:
		return false
	var document := value as Dictionary
	if route in ["main_menu", "saves", "join_friend", "deploying",
			"session", "bunker", "build_mode", "crafting", "pause"]:
		_prepare_frontflow(document)
	if route in ["session", "bunker", "build_mode", "crafting", "pause"]:
		BunkerFixture.initialize(document)
	if route in ["inventory", "health", "stats"]:
		_prepare_character(document)
	if route in ["deploying", "hud", "hud_coop", "pause",
			"summary_solo", "summary_squad", "reload", "mag_empty",
			"hud_detail", "status_icons", "squad_list", "crosshairs"]:
		_prepare_raid(document)
	return true


func catalog(name: StringName, expected_generation: int) -> Variant:
	last_error = &""
	if not is_current(expected_generation):
		last_error = &"fixture_provider_stale_generation" \
				if _active else &"fixture_provider_released"
		return null
	match name:
		&"zones":
			return UtilityFixture.ZONES.duplicate(true)
		&"tasks":
			return UtilityFixture.TASKS.duplicate(true)
		&"traders":
			return UtilityFixture.TRADERS.duplicate(true)
		&"control_groups":
			return UtilityFixture.CONTROL_GROUPS.duplicate(true)
		&"default_bindings":
			return UtilityFixture.DEFAULT_BINDINGS.duplicate(true)
	last_error = &"fixture_catalog_unknown"
	return null


func teardown(expected_generation: int = -1) -> bool:
	last_error = &""
	if not _active:
		return true
	if expected_generation >= 0 and expected_generation != _generation:
		return _reject(&"fixture_provider_teardown_generation_mismatch")
	# As with replacement, detach instead of clearing the retired document.
	# This prevents a stale Dictionary reference from observing or changing a
	# future fixture session.
	_store = ZUIFixtureStore.new()
	_active = false
	return true


func _prepare_frontflow(document: Dictionary) -> void:
	if not document.has("frontflow_worlds"):
		document["frontflow_worlds"] = FrontflowFixture.worlds()
	if not document.has("frontflow_selected_world"):
		document["frontflow_selected_world"] = 0


func _prepare_character(document: Dictionary) -> void:
	if not document.has("inventory_data"):
		document["inventory_data"] = InventoryFixture.create()
	if not document.has("inventory_tab"):
		document["inventory_tab"] = "gear"
	if not document.has("med_count"):
		document["med_count"] = 2


func _prepare_raid(document: Dictionary) -> void:
	if not document.has("raid_ammo"):
		document["raid_ammo"] = 24
	if not document.has("raid_reloading"):
		document["raid_reloading"] = false
	if not document.has("raid_low_health"):
		document["raid_low_health"] = false
	if not document.has("squad_ready"):
		document["squad_ready"] = false


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
