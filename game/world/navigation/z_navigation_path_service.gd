class_name ZNavigationPathService
extends RefCounted
## The game-owned deterministic path-request seam (task 3.9).
##
## Contract of the seam:
## - request_path(start, goal, expected_revision, budget_nodes) returns one
##   typed ZNavigationPathResult and nothing else. Outcomes are closed:
##   ok, unreachable, start_blocked, goal_blocked, out_of_bounds,
##   budget_exhausted, stale_revision. There is no bare-array return.
## - The same (start, goal, revision, budget) always yields the same path:
##   the search is a pure deterministic function, and the optional cache is
##   keyed by navigation revision bound to the grid digest, hard-cleared on
##   every (re)bind, and verified on every hit, so a result can never be
##   silently stale.
## - Every request carries an explicit node-expansion budget. Reaching the
##   budget before the goal returns budget_exhausted, never an unbounded
##   search.
## - Path results are derived advisory data. This service registers with no
##   authority phase, submits no intents, and writes nothing to Inventory,
##   Weapon, Gameplay Ability, Common Vision or Level Task state. Issuing any
##   number of requests — fresh, cached or failing — must leave the canonical
##   raid state digest bit-identical.
## - Generations and teardown: a request carrying a stale revision, or any
##   request after seal(), returns stale_revision and mutates nothing.

const DEFAULT_BUDGET_NODES: int = 4096
const MAX_CACHE_ENTRIES: int = 64

var last_error: StringName = &""
var _grid: ZNavigationGrid = null
var _revision: int = -1
var _revision_block: String = ""
var _cache: Dictionary = {}
var _cache_order: Array[String] = []
var _sealed: bool = false
var _configured: bool = false


## Binds one baked grid and its navigation revision. Rebinding is allowed only
## under a NEW revision; rebinding the same revision is refused because it
## could leave cache entries that outlive the grid they were computed from.
## Every bind hard-clears the cache.
func configure(grid: ZNavigationGrid, expected_revision: int) -> bool:
	last_error = &""
	if _sealed:
		return _fail(&"service_sealed")
	if grid == null:
		return _fail(&"grid_missing")
	if not grid.is_baked():
		return _fail(&"grid_unbaked")
	if expected_revision < 0:
		return _fail(&"revision_invalid")
	if grid.revision() != expected_revision:
		return _fail(&"revision_mismatch")
	if _configured and expected_revision == _revision:
		return _fail(&"revision_unchanged")
	_grid = grid
	_revision = expected_revision
	_revision_block = "%d:%s" % [expected_revision, grid.digest()]
	_cache.clear()
	_cache_order.clear()
	_configured = true
	return true


func is_configured() -> bool:
	return _configured


func is_sealed() -> bool:
	return _sealed


func revision() -> int:
	return _revision


func grid() -> ZNavigationGrid:
	return _grid


func cache_entry_count() -> int:
	return _cache.size()


## One path request. Order of outcome checks is fixed and documented:
## stale_revision, then out_of_bounds, then start_blocked, then goal_blocked,
## then budget_exhausted (with zero work), then the bounded search. Only ok
## results are cached; failing outcomes never poison a later request made
## with a larger budget.
func request_path(
	start: Vector2i,
	goal: Vector2i,
	expected_revision: int,
	budget_nodes: int = DEFAULT_BUDGET_NODES
) -> ZNavigationPathResult:
	last_error = &""
	if not _configured or _sealed or expected_revision < 0 \
			or expected_revision != _revision:
		return _stale(expected_revision, start, goal, budget_nodes)
	if not _grid.has_cell(start) or not _grid.has_cell(goal):
		return _failure(
			ZNavigationPathResult.OUTCOME_OUT_OF_BOUNDS,
			start, goal, budget_nodes
		)
	if _grid.is_blocked(start):
		return _failure(
			ZNavigationPathResult.OUTCOME_START_BLOCKED,
			start, goal, budget_nodes
		)
	if _grid.is_blocked(goal):
		return _failure(
			ZNavigationPathResult.OUTCOME_GOAL_BLOCKED,
			start, goal, budget_nodes
		)
	if budget_nodes < 1:
		return _failure(
			ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED,
			start, goal, budget_nodes
		)
	var key := _cache_key(start, goal, budget_nodes)
	if _cache.has(key):
		var cached_record: Dictionary = _cache[key]
		if String(cached_record["revision_block"]) == _revision_block:
			return _result_from_cache(cached_record)
		# Defensive invalidation: an entry from another revision binding is
		# dropped, never served.
		_cache.erase(key)
		_cache_order.erase(key)
	var search: Dictionary = ZNavigationAStar.search(_grid, start, goal, budget_nodes)
	var result := ZNavigationPathResult.new()
	result.outcome = search["outcome"]
	result.revision = _revision
	result.start = start
	result.goal = goal
	result.cost = int(search["cost"])
	result.expanded_nodes = int(search["expanded_nodes"])
	result.budget_nodes = budget_nodes
	var search_cells: Array[Vector2i] = search["cells"]
	for cell in search_cells:
		result.cells.append(cell)
	if result.is_ok():
		_store_cache(key, result)
		last_error = &""
	else:
		last_error = result.outcome
	return result


## Explicit cache invalidation for the current revision. Results are dropped,
## never silently retained.
func invalidate_cache(expected_revision: int) -> bool:
	last_error = &""
	if not _configured or _sealed or expected_revision != _revision:
		return _fail(&"stale_revision")
	_cache.clear()
	_cache_order.clear()
	return true


## Terminal teardown. Every later request returns stale_revision and mutates
## nothing, regardless of the revision a late caller presents.
func seal(expected_revision: int) -> bool:
	last_error = &""
	if not _configured:
		return _fail(&"service_unconfigured")
	if expected_revision != _revision:
		return _fail(&"stale_revision")
	_sealed = true
	_cache.clear()
	_cache_order.clear()
	return true


func _cache_key(start: Vector2i, goal: Vector2i, budget_nodes: int) -> String:
	return "%s|s%d,%d|g%d,%d|b%d" % [
		_revision_block, start.x, start.y, goal.x, goal.y, budget_nodes,
	]


func _store_cache(key: String, result: ZNavigationPathResult) -> void:
	while _cache_order.size() >= MAX_CACHE_ENTRIES:
		var oldest := _cache_order[0]
		_cache_order.remove_at(0)
		_cache.erase(oldest)
	var cells: Array[Vector2i] = []
	for cell in result.cells:
		cells.append(cell)
	_cache[key] = {
		"budget_nodes": result.budget_nodes,
		"cells": cells,
		"cost": result.cost,
		"expanded_nodes": result.expanded_nodes,
		"goal": result.goal,
		"outcome": result.outcome,
		"revision": result.revision,
		"revision_block": _revision_block,
		"start": result.start,
	}
	_cache_order.append(key)


func _result_from_cache(cached_record: Dictionary) -> ZNavigationPathResult:
	var result := ZNavigationPathResult.new()
	result.outcome = cached_record["outcome"]
	result.revision = int(cached_record["revision"])
	result.start = cached_record["start"]
	result.goal = cached_record["goal"]
	var cached_cells: Array[Vector2i] = cached_record["cells"]
	result.cells = cached_cells.duplicate()
	result.cost = int(cached_record["cost"])
	result.expanded_nodes = int(cached_record["expanded_nodes"])
	result.budget_nodes = int(cached_record["budget_nodes"])
	result.cached = true
	last_error = &""
	return result


func _failure(
	outcome: StringName,
	start: Vector2i,
	goal: Vector2i,
	budget_nodes: int
) -> ZNavigationPathResult:
	last_error = outcome
	return ZNavigationPathResult.failure(outcome, _revision, start, goal, budget_nodes)


func _stale(
	expected_revision: int,
	start: Vector2i,
	goal: Vector2i,
	budget_nodes: int
) -> ZNavigationPathResult:
	last_error = &"stale_revision"
	return ZNavigationPathResult.failure(
		ZNavigationPathResult.OUTCOME_STALE_REVISION,
		expected_revision, start, goal, budget_nodes
	)


func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
