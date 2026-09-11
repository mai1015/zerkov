class_name ZUIPresentationProvider
extends Node

## Generation-scoped publication seam for non-Character production screens.
##
## This provider owns no gameplay/profile state and exposes no mutation API.
## Product composition may inject already-built immutable views.  In the
## current partial product composition, every missing service publishes a
## typed unavailable view. Character inventory/health deliberately keep their
## accepted, narrower CharacterPresentationComposition seam.

signal published(generation: int)
signal invalidated(generation: int, reason: StringName)

const DEFAULT_REASON: StringName = &"ui_services_not_injected"

var last_error: StringName = &""

var _initialized: bool = false
var _active: bool = false
var _generation: int = 0
var _bunker_view: BunkerView
var _raid_view: RaidView
var _task_view: TaskView
var _map_view: MapView
var _summary_view: SummaryView


func start_unavailable(
	p_generation: int = 1,
	reason: StringName = DEFAULT_REASON
) -> bool:
	last_error = &""
	if _initialized or p_generation <= 0:
		return _reject(&"ui_presentation_provider_start_invalid")
	_generation = p_generation
	_initialized = true
	_active = true
	_assign_unavailable(reason)
	published.emit(_generation)
	return true


func is_initialized() -> bool:
	return _initialized


func is_active() -> bool:
	return _initialized and _active


func generation() -> int:
	return _generation


## Atomically publishes one complete same-generation set. Callers explicitly
## pass unavailable views for services they do not own; null never means sample
## data. Equal-version replacement requires the exact immutable instance.
func publish_views(
	p_generation: int,
	bunker: BunkerView,
	raid: RaidView,
	tasks: TaskView,
	map: MapView,
	summary: SummaryView
) -> bool:
	last_error = &""
	if not is_active() or p_generation != _generation:
		return _reject(&"ui_presentation_provider_generation_mismatch")
	var views: Array[ZReadOnlyView] = [bunker, raid, tasks, map, summary]
	if not _views_are_valid(views, p_generation):
		return _reject(&"ui_presentation_provider_view_invalid")
	var current: Array[ZReadOnlyView] = [
		_bunker_view, _raid_view, _task_view, _map_view, _summary_view]
	for index in views.size():
		if views[index].revision() < current[index].revision() \
				or views[index].source_tick() < current[index].source_tick():
			return _reject(&"ui_presentation_provider_version_regressed")
		if views[index].revision() == current[index].revision() \
				and views[index].source_tick() == current[index].source_tick() \
				and views[index] != current[index]:
			return _reject(&"ui_presentation_provider_version_divergent")
	_assign_views(bunker, raid, tasks, map, summary)
	published.emit(_generation)
	return true


## Authority/profile replacement is fail-atomic and must advance generation.
func replace_views(
	next_generation: int,
	bunker: BunkerView,
	raid: RaidView,
	tasks: TaskView,
	map: MapView,
	summary: SummaryView
) -> bool:
	last_error = &""
	if not is_active() or next_generation <= _generation:
		return _reject(&"ui_presentation_provider_replacement_invalid")
	var views: Array[ZReadOnlyView] = [bunker, raid, tasks, map, summary]
	if not _views_are_valid(views, next_generation):
		return _reject(&"ui_presentation_provider_view_invalid")
	_generation = next_generation
	_assign_views(bunker, raid, tasks, map, summary)
	published.emit(_generation)
	return true


func replace_unavailable(
	next_generation: int,
	reason: StringName = DEFAULT_REASON
) -> bool:
	last_error = &""
	if not is_active() or next_generation <= _generation or reason.is_empty():
		return _reject(&"ui_presentation_provider_replacement_invalid")
	_generation = next_generation
	_assign_unavailable(reason)
	published.emit(_generation)
	return true


func bunker_view(expected_generation: int) -> BunkerView:
	if _lease_is_current(expected_generation):
		return _bunker_view
	return BunkerView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND, _lease_reason(),
		expected_generation if expected_generation > 0 else 0)


func raid_view(expected_generation: int) -> RaidView:
	if _lease_is_current(expected_generation):
		return _raid_view
	return RaidView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND, _lease_reason(),
		expected_generation if expected_generation > 0 else 0)


func task_view(expected_generation: int) -> TaskView:
	if _lease_is_current(expected_generation):
		return _task_view
	return TaskView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND, _lease_reason(),
		expected_generation if expected_generation > 0 else 0)


func map_view(expected_generation: int) -> MapView:
	if _lease_is_current(expected_generation):
		return _map_view
	return MapView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND, _lease_reason(),
		expected_generation if expected_generation > 0 else 0)


func summary_view(expected_generation: int) -> SummaryView:
	if _lease_is_current(expected_generation):
		return _summary_view
	return SummaryView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND, _lease_reason(),
		expected_generation if expected_generation > 0 else 0)


func view_for_route(route: String, expected_generation: int) -> ZReadOnlyView:
	if route in ["main_menu", "saves", "join_friend", "session", "bunker",
			"build_mode", "crafting"]:
		return bunker_view(expected_generation)
	if route in ["deploying", "hud", "hud_coop", "pause"]:
		return raid_view(expected_generation)
	if route == "tasks":
		return task_view(expected_generation)
	if route == "maps":
		return map_view(expected_generation)
	if route in ["summary_solo", "summary_squad"]:
		return summary_view(expected_generation)
	return null


func teardown(expected_generation: int = -1) -> bool:
	last_error = &""
	if not _initialized or not _active:
		return true
	if expected_generation >= 0 and expected_generation != _generation:
		return _reject(&"ui_presentation_provider_teardown_generation_mismatch")
	_active = false
	_assign_unavailable(&"ui_presentation_provider_released")
	invalidated.emit(_generation, &"ui_presentation_provider_released")
	return true


func _exit_tree() -> void:
	teardown(_generation)


func _lease_is_current(expected_generation: int) -> bool:
	return is_active() and expected_generation > 0 \
			and expected_generation == _generation


func _lease_reason() -> StringName:
	return &"ui_presentation_provider_stale_generation" \
			if is_active() else &"ui_presentation_provider_released"


func _views_are_valid(views: Array[ZReadOnlyView], expected_generation: int) -> bool:
	for view in views:
		if view == null or not view.is_initialized() \
				or view.generation() != expected_generation:
			return false
	return true


func _assign_views(
	bunker: BunkerView,
	raid: RaidView,
	tasks: TaskView,
	map: MapView,
	summary: SummaryView
) -> void:
	_bunker_view = bunker
	_raid_view = raid
	_task_view = tasks
	_map_view = map
	_summary_view = summary


func _assign_unavailable(reason: StringName) -> void:
	var base_reason := reason if not reason.is_empty() else DEFAULT_REASON
	_bunker_view = BunkerView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		StringName("%s_bunker" % String(base_reason)), _generation)
	_raid_view = RaidView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		StringName("%s_raid" % String(base_reason)), _generation)
	_task_view = TaskView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		StringName("%s_tasks" % String(base_reason)), _generation)
	_map_view = MapView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		StringName("%s_map" % String(base_reason)), _generation)
	_summary_view = SummaryView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		StringName("%s_summary" % String(base_reason)), _generation)


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
