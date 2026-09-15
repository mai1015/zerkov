class_name ZNavigationAStar
extends RefCounted
## Deterministic bounded A* over a ZNavigationGrid (task 3.9).
##
## Every ordering decision is explicit and total:
## - all costs are integers: 10 per orthogonal step, 14 per diagonal step;
## - the open list is an array-based binary heap whose entries compare by
##   (f, then h, then cell y, then cell x) — a total order over entries;
## - neighbours are generated in one fixed authored order;
## - a cell's parent is replaced only on a strictly better cost, so equal
##   candidates resolve to the first expansion and never to Dictionary or
##   Set iteration order;
## - no float arithmetic is used for cost or ordering anywhere.
## The search is a pure function of (grid geometry, start, goal, budget); it
## allocates no node objects, registers nothing, and mutates nothing outside
## its own locals.

const COST_ORTHOGONAL: int = 10
const COST_DIAGONAL: int = 14
## Fixed neighbour generation order. Never reordered, never shuffled.
const NEIGHBOR_STEPS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]


## Returns {"outcome": StringName, "cells": Array[Vector2i], "cost": int,
## "expanded_nodes": int}. Callers validate bounds and blocking first; the
## search assumes start and goal are walkable grid cells. Diagonal steps may
## not cut a blocked corner: both shared-edge cells must be walkable.
static func search(
	grid: ZNavigationGrid,
	start: Vector2i,
	goal: Vector2i,
	budget_nodes: int
) -> Dictionary:
	var record := {
		"outcome": ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED,
		"cells": [] as Array[Vector2i],
		"cost": 0,
		"expanded_nodes": 0,
	}
	if budget_nodes < 1:
		return record
	var g_score: Dictionary = {start: 0}
	var parent: Dictionary = {}
	var closed: Dictionary = {}
	var open: Array = []
	_heap_push(open, start, 0, heuristic(start, goal))
	var expanded := 0
	while not open.is_empty():
		var entry: Dictionary = _heap_pop(open)
		var cell: Vector2i = entry["cell"]
		if closed.has(cell) or int(g_score.get(cell, -1)) != int(entry["g"]):
			continue
		closed[cell] = true
		expanded += 1
		if cell == goal:
			record["outcome"] = ZNavigationPathResult.OUTCOME_OK
			record["cells"] = _reconstruct(parent, start, goal)
			record["cost"] = int(entry["g"])
			record["expanded_nodes"] = expanded
			return record
		if expanded >= budget_nodes:
			record["outcome"] = ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED
			record["expanded_nodes"] = expanded
			return record
		for step_value in NEIGHBOR_STEPS:
			var step: Vector2i = step_value
			var next := cell + step
			if not grid.is_walkable(next):
				continue
			var diagonal := step.x != 0 and step.y != 0
			if diagonal and not _corner_open(grid, cell, step):
				continue
			var step_cost := COST_DIAGONAL if diagonal else COST_ORTHOGONAL
			var candidate_g := int(entry["g"]) + step_cost
			if g_score.has(next) and int(g_score[next]) <= candidate_g:
				continue
			g_score[next] = candidate_g
			parent[next] = cell
			_heap_push(open, next, candidate_g, heuristic(next, goal))
	record["outcome"] = ZNavigationPathResult.OUTCOME_UNREACHABLE
	record["expanded_nodes"] = expanded
	return record


## Admissible and consistent integer octile lower bound. Never compares or
## stores floats; derived only from the two step-cost constants above.
static func heuristic(a: Vector2i, b: Vector2i) -> int:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return COST_ORTHOGONAL * (dx + dy) \
			- (COST_DIAGONAL - 2 * COST_ORTHOGONAL) * mini(dx, dy)


static func _corner_open(
	grid: ZNavigationGrid, cell: Vector2i, step: Vector2i
) -> bool:
	return grid.is_walkable(Vector2i(cell.x + step.x, cell.y)) \
			and grid.is_walkable(Vector2i(cell.x, cell.y + step.y))


static func _reconstruct(
	parent: Dictionary, start: Vector2i, goal: Vector2i
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var cursor := goal
	while cursor != start:
		cells.append(cursor)
		if not parent.has(cursor):
			break
		cursor = parent[cursor]
	cells.append(start)
	cells.reverse()
	return cells


## Total order over heap entries: f, then h, then cell (y, then x). Distinct
## cells are never equal, so the order is total and stable.
static func _entry_less(a: Dictionary, b: Dictionary) -> bool:
	var f_a := int(a["f"])
	var f_b := int(b["f"])
	if f_a != f_b:
		return f_a < f_b
	var h_a := int(a["h"])
	var h_b := int(b["h"])
	if h_a != h_b:
		return h_a < h_b
	var cell_a: Vector2i = a["cell"]
	var cell_b: Vector2i = b["cell"]
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	return cell_a.x < cell_b.x


static func _heap_push(
	open: Array, cell: Vector2i, g: int, h: int
) -> void:
	open.push_back({"cell": cell, "g": g, "f": g + h, "h": h})
	var index := open.size() - 1
	while index > 0:
		var parent_index := (index - 1) / 2
		if not _entry_less(open[index], open[parent_index]):
			break
		var swapped: Dictionary = open[parent_index]
		open[parent_index] = open[index]
		open[index] = swapped
		index = parent_index


static func _heap_pop(open: Array) -> Dictionary:
	var top: Dictionary = open[0]
	open[0] = open[open.size() - 1]
	open.pop_back()
	var size := open.size()
	var index := 0
	while true:
		var left := 2 * index + 1
		var right := left + 1
		var best := index
		if left < size and _entry_less(open[left], open[best]):
			best = left
		if right < size and _entry_less(open[right], open[best]):
			best = right
		if best == index:
			break
		var swapped: Dictionary = open[index]
		open[index] = open[best]
		open[best] = swapped
		index = best
	return top
