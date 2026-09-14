class_name ZNavigationPathResult
extends RefCounted
## Typed outcome of one navigation path request (task 3.9).
##
## A pure value object: it holds no reference to any world, authority or
## add-on state and can never be written back through itself. Path results
## are derived, advisory steering data for AI controllers; they MUST NOT be
## stored in Inventory, Weapon, Gameplay Ability, Common Vision or Level Task
## native state and never take part in a canonical raid digest. A controller
## that follows a path still submits movement intents and lets authoritative
## collision resolve the actual motion.
##
## Outcomes are closed and typed; there is no bare-array or nullable return:
## ok, unreachable, start_blocked, goal_blocked, out_of_bounds,
## budget_exhausted, stale_revision.

const OUTCOME_OK: StringName = &"ok"
const OUTCOME_UNREACHABLE: StringName = &"unreachable"
const OUTCOME_START_BLOCKED: StringName = &"start_blocked"
const OUTCOME_GOAL_BLOCKED: StringName = &"goal_blocked"
const OUTCOME_OUT_OF_BOUNDS: StringName = &"out_of_bounds"
const OUTCOME_BUDGET_EXHAUSTED: StringName = &"budget_exhausted"
const OUTCOME_STALE_REVISION: StringName = &"stale_revision"

var outcome: StringName = &""
var revision: int = -1
var start: Vector2i = Vector2i.ZERO
var goal: Vector2i = Vector2i.ZERO
var cells: Array[Vector2i] = []
var cost: int = 0
var expanded_nodes: int = 0
var budget_nodes: int = 0
## True when this value was served from the revision-keyed cache. Deliberately
## excluded from canonical_record(): a cache hit must digest identically to a
## fresh computation of the same path.
var cached: bool = false


static func failure(
	p_outcome: StringName,
	p_revision: int,
	p_start: Vector2i,
	p_goal: Vector2i,
	p_budget_nodes: int
) -> ZNavigationPathResult:
	var result := ZNavigationPathResult.new()
	result.outcome = p_outcome
	result.revision = p_revision
	result.start = p_start
	result.goal = p_goal
	result.budget_nodes = p_budget_nodes
	return result


func is_ok() -> bool:
	return outcome == OUTCOME_OK


func path_cell_count() -> int:
	return cells.size()


## Advisory record for auditing a result. Bounded for any path length. The
## request budget is deliberately excluded: for the same navigation revision
## an ok path is identical whichever budget (large enough to finish) produced
## it, and the digest must express that identity.
func canonical_record() -> Dictionary:
	return {
		"cells_count": cells.size(),
		"cells_digest": ZNavigationGrid.digest_cell_array(cells),
		"cost": cost,
		"expanded_nodes": expanded_nodes,
		"goal": goal,
		"outcome": String(outcome),
		"revision": revision,
		"start": start,
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())
