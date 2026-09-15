class_name ZInteractionPolicy
extends RefCounted
## Task 3.8 -- the single authoritative answer to "may actor A interact with
## target T right now?" for doors, crates, corpses, heal targets and
## extraction zones.
##
## Pure evaluator over injected state: this module is entirely static, never
## mutates a target, never loads a scene or resource, and holds no state. It
## only reads a `ZInteractionRequest`, a `String -> ZInteractionTargetState`
## index and the task 3.10 baked occluder segments, and returns a typed
## `ZInteractionResult`. `ZInteractionPolicyOwner` is the only composition
## caller: it registers the INTERACTIONS_AND_WEAPONS phase handler with
## `RaidAuthority` and feeds this evaluator authoritative state. Presentation
## can read results, never reach this policy as a mutation path.
##
## Range policy: every kind but `extraction_zone` uses its own explicit bounded
## range authored in WORLD UNITS below. The authored unit value crosses to
## Godot px only through the `ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT`
## vocabulary and to canonical (Vision) microunits only through
## `ZWorldUnits.godot_to_canonical` -- never a shared/global radius, never an
## open-coded `* 32` / `* 1_000_000 / 32` scale. Every comparison happens on
## exact 64-bit integers in canonical microunit space, never on float pixels
## and never with a tolerance, so boundary results are bit-for-bit
## deterministic. `extraction_zone` is deliberately different: it uses the
## marker's authored `zone_cells` tile containment (an exact discrete check)
## instead of a radius, because an extraction pad is an area you stand inside,
## not a point you stand near -- see `_resolve_extraction_zone`.
##
## Line-of-interaction policy: a blocking occluder segment between the actor
## and the target's authored interaction point denies the interaction. This
## reuses task 3.10's baked `ZerkovOccluderSegment` list verbatim (no
## re-derived geometry, no physics raycast) and only treats
## `ZOccluderBake.MASK_STRUCTURE` segments as physically blocking --
## vegetation-only occluders block Vision sight but not physical reach, the
## same authored-layer policy `ZMovementWorldBuilder` applies to movement. A
## target never blocks its own interaction line: door targets are authored
## from the same gate structures that bake into these segments, so a door's
## own outline is exempt via the segment's `source_ids` provenance while every
## other structure still blocks. Segment crossing is exact integer
## orientation math (see `_segments_intersect`), never a float tolerance.
##
## Eligibility policy: each kind has one explicit current-state predicate
## (`_is_eligible`) read from the target's injected `eligibility_context`.
## Owning authorities for most of these flags (locks, container contents,
## health, objective gating) do not exist yet in the first playable, so each
## flag is an injected, documented default rather than a new authority
## invented here.

## Authored per-kind bounded ranges in world units. Each kind owns its own
## constant on purpose -- do not collapse these into one shared radius. All
## four values are exact binary fractions, so the derived px and microunit
## ranges are exact integers. `extraction_zone` has no radius entry by
## design; see `range_px_for_kind`.
const DOOR_RANGE_WORLD_UNITS: float = 1.5 ## reach to open/use a door.
const CRATE_RANGE_WORLD_UNITS: float = 1.25 ## reach into a loot container.
const CORPSE_RANGE_WORLD_UNITS: float = 1.5 ## reach to loot a body.
const HEAL_TARGET_RANGE_WORLD_UNITS: float = 2.0 ## treat self or a nearby ally.

const NO_RANGE_PX: float = -1.0
const NO_RANGE_MICRO: int = -1


static func range_px_for_kind(kind: StringName) -> float:
	match kind:
		ZInteractionKind.DOOR:
			return DOOR_RANGE_WORLD_UNITS * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT
		ZInteractionKind.CRATE:
			return CRATE_RANGE_WORLD_UNITS * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT
		ZInteractionKind.CORPSE:
			return CORPSE_RANGE_WORLD_UNITS * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT
		ZInteractionKind.HEAL_TARGET:
			return HEAL_TARGET_RANGE_WORLD_UNITS * ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT
		_:
			return NO_RANGE_PX


## Converts the authored range to canonical (Vision) microunits through
## `ZWorldUnits` only -- the one checked conversion boundary. Returns `-1` for
## `extraction_zone` (no radius; containment instead) or an unconvertible
## range.
static func range_micro_for_kind(kind: StringName) -> int:
	var range_px := range_px_for_kind(kind)
	if range_px < 0.0:
		return NO_RANGE_MICRO
	var conversion := ZWorldUnits.godot_to_canonical(Vector2(range_px, 0.0))
	return conversion.vector2i_value.x if conversion.ok else NO_RANGE_MICRO


## Main px-facing entry point. Converts the actor's Godot-space position to
## canonical microunits (the only place a float touches this decision) and
## delegates every comparison to `evaluate_micro`.
static func evaluate(
	request: ZInteractionRequest,
	targets: Dictionary,
	occluders: Array[ZerkovOccluderSegment]
) -> ZInteractionResult:
	if request == null:
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_INVALID_REQUEST, &"", &""
		)
	var actor_conversion := ZWorldUnits.godot_to_canonical(request.actor_position_px)
	if not actor_conversion.ok:
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_INVALID_REQUEST, request.target_id, &""
		)
	return evaluate_micro(
		actor_conversion.vector2i_value,
		request.target_id,
		request.requested_kind,
		targets,
		occluders
	)


## Exact-integer entry point: `actor_micro` is already canonical (Vision)
## microunits, so callers that need bit-exact control over a boundary
## (contract tests) can drive this directly with zero float rounding anywhere
## in the call. Production code reaches this only through `evaluate`.
static func evaluate_micro(
	actor_micro: Vector2i,
	target_id: StringName,
	requested_kind: StringName,
	targets: Dictionary,
	occluders: Array[ZerkovOccluderSegment]
) -> ZInteractionResult:
	if not _is_bounded_micro_point(actor_micro):
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_INVALID_REQUEST, target_id, requested_kind
		)
	if String(target_id).is_empty():
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_UNKNOWN_TARGET, target_id, requested_kind
		)
	var indexed: Variant = targets.get(String(target_id), null)
	if not indexed is ZInteractionTargetState:
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_UNKNOWN_TARGET, target_id, requested_kind
		)
	var target: ZInteractionTargetState = indexed
	if requested_kind != target.kind:
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_WRONG_KIND, target_id, target.kind
		)
	var interaction_point := ZWorldUnits.godot_to_canonical(target.position_px)
	if not interaction_point.ok:
		# For point kinds this is the target itself; for an extraction zone it
		# is the marker's authored anchor cell. Either way an unconvertible
		# interaction point is bad injected state, fail closed.
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_INVALID_REQUEST, target_id, target.kind
		)
	var target_micro: Vector2i = interaction_point.vector2i_value

	var within_range := false
	var distance_micro := NO_RANGE_MICRO
	if target.kind == ZInteractionKind.EXTRACTION_ZONE:
		var zone := _resolve_extraction_zone(actor_micro, target.zone_cells)
		if not bool(zone.get("ok", false)):
			return ZInteractionResult.deny(
				ZInteractionResult.REASON_INVALID_REQUEST, target_id, target.kind
			)
		within_range = bool(zone["inside"])
		distance_micro = int(zone["distance_micro"])
	else:
		var dx: int = actor_micro.x - target_micro.x
		var dy: int = actor_micro.y - target_micro.y
		var range_micro := range_micro_for_kind(target.kind)
		# |axis| > range already implies distance > range, so the squared
		# comparison below only ever sees axes bounded by the authored range
		# (<= 2,000,000 micro): the 64-bit squares cannot overflow.
		if range_micro >= 0 and absi(dx) <= range_micro and absi(dy) <= range_micro:
			within_range = dx * dx + dy * dy <= range_micro * range_micro
		distance_micro = _distance_micro(dx, dy)

	if not within_range:
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_OUT_OF_RANGE, target_id, target.kind,
			distance_micro
		)
	if _line_blocked(actor_micro, target_micro, occluders, target.target_id):
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_LINE_BLOCKED, target_id, target.kind,
			distance_micro
		)
	if not _is_eligible(target.kind, target.eligibility_context):
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_INELIGIBLE, target_id, target.kind,
			distance_micro
		)
	return ZInteractionResult.allow(target_id, target.kind, distance_micro)


## `extraction_zone` containment per the documented radius-vs-area split: the
## actor's discrete tile -- derived from canonical microunits through the two
## checked `ZWorldUnits` conversions only -- must fall inside the marker's
## authored `zone_cells`. That is an exact integer tile check, not a distance
## comparison. `distance_micro`/`nearest_point_micro` are still resolved
## (clamped to the zone's canonical bounds) so a denial reports a meaningful
## distance even though no radius exists for this kind.
static func _resolve_extraction_zone(actor_micro: Vector2i, zone_cells: Rect2i) -> Dictionary:
	var actor_px := ZWorldUnits.canonical_to_godot(actor_micro)
	if not actor_px.ok:
		return {"ok": false}
	var actor_tile := ZWorldUnits.godot_to_tile(actor_px.vector2_value)
	if not actor_tile.ok:
		return {"ok": false}
	var min_origin := ZWorldUnits.tile_origin_to_godot(zone_cells.position)
	var max_origin := ZWorldUnits.tile_origin_to_godot(zone_cells.position + zone_cells.size)
	if not min_origin.ok or not max_origin.ok:
		return {"ok": false}
	var min_conversion := ZWorldUnits.godot_to_canonical(min_origin.vector2_value)
	var max_conversion := ZWorldUnits.godot_to_canonical(max_origin.vector2_value)
	if not min_conversion.ok or not max_conversion.ok:
		return {"ok": false}
	var min_micro: Vector2i = min_conversion.vector2i_value
	var max_micro: Vector2i = max_conversion.vector2i_value
	var nearest := Vector2i(
		clampi(actor_micro.x, min_micro.x, max_micro.x),
		clampi(actor_micro.y, min_micro.y, max_micro.y)
	)
	var dx: int = actor_micro.x - nearest.x
	var dy: int = actor_micro.y - nearest.y
	return {
		"ok": true,
		"inside": zone_cells.has_point(actor_tile.vector2i_value),
		"distance_micro": _distance_micro(dx, dy),
		"nearest_point_micro": nearest,
	}


## Only `ZOccluderBake.MASK_STRUCTURE` segments physically block an
## interaction line; vegetation-only (Canopy) segments block Vision sight but
## not physical reach, mirroring `ZMovementWorldBuilder`'s movement-blocking
## policy for the same authored layers. Segments contributed by the target
## itself (a door target's own gate outline) are exempt via `source_ids`.
static func _line_blocked(
	a: Vector2i,
	b: Vector2i,
	occluders: Array[ZerkovOccluderSegment],
	target_id: StringName
) -> bool:
	for segment in occluders:
		if segment == null or segment.is_degenerate():
			continue
		if (segment.mask & ZOccluderBake.MASK_STRUCTURE) == 0:
			continue
		if segment.source_ids.has(String(target_id)):
			continue
		if _segments_intersect(a, b, segment.a, segment.b):
			return true
	return false


static func _is_eligible(kind: StringName, context: Dictionary) -> bool:
	match kind:
		ZInteractionKind.DOOR:
			# Documented default: unlocked. No lock authority exists yet in
			# the first playable; a future owner sets `locked:true`.
			return not bool(context.get("locked", false))
		ZInteractionKind.CRATE, ZInteractionKind.CORPSE:
			# Documented default: lootable. No container-emptied tracking is
			# wired to interaction policy yet; a future owner sets
			# `lootable:false` once a container/corpse is fully looted.
			return bool(context.get("lootable", true))
		ZInteractionKind.HEAL_TARGET:
			# Documented defaults: alive, NOT injured. Healing fails closed
			# until real health/injury state (no authority exists yet) says
			# the target is actually injured; an owner sets
			# {"alive": true, "injured": true} for a genuinely treatable
			# target.
			return bool(context.get("alive", true)) and bool(context.get("injured", false))
		ZInteractionKind.EXTRACTION_ZONE:
			# Documented default: open. No Level Task / objective-gating owner
			# exists yet in the first playable; a future owner sets
			# `open:false` until the raid's objective is complete.
			return bool(context.get("open", true))
		_:
			return false


## Exact integer segment-intersection test (orientation/cross-product form).
## A touching endpoint counts as a crossing (conservative: an interaction
## line that just grazes an occluder is treated as blocked). Inputs are
## bounded: interaction lines are at most one authored range long (<= 2,000,000
## micro) or span the authored level (<= ~40,000,000 micro for the 40x20-cell
## Sawmill), and baked segment endpoints lie inside the level, so every
## cross product stays under 64-bit overflow with a margin of >100x.
static func _segments_intersect(p1: Vector2i, p2: Vector2i, p3: Vector2i, p4: Vector2i) -> bool:
	var o1 := _orientation(p1, p2, p3)
	var o2 := _orientation(p1, p2, p4)
	var o3 := _orientation(p3, p4, p1)
	var o4 := _orientation(p3, p4, p2)

	if o1 != o2 and o3 != o4:
		return true
	if o1 == 0 and _point_on_segment(p1, p2, p3):
		return true
	if o2 == 0 and _point_on_segment(p1, p2, p4):
		return true
	if o3 == 0 and _point_on_segment(p3, p4, p1):
		return true
	if o4 == 0 and _point_on_segment(p3, p4, p2):
		return true
	return false


static func _orientation(a: Vector2i, b: Vector2i, c: Vector2i) -> int:
	var cross: int = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	if cross > 0:
		return 1
	if cross < 0:
		return -1
	return 0


static func _point_on_segment(a: Vector2i, b: Vector2i, p: Vector2i) -> bool:
	return mini(a.x, b.x) <= p.x and p.x <= maxi(a.x, b.x) \
		and mini(a.y, b.y) <= p.y and p.y <= maxi(a.y, b.y)


static func _is_bounded_micro_point(point: Vector2i) -> bool:
	return absi(point.x) <= ZWorldUnits.MAX_VISION_CANONICAL_RAW \
		and absi(point.y) <= ZWorldUnits.MAX_VISION_CANONICAL_RAW


## Resolved distance for the typed result. Informational only: the allow/deny
## decision compares squared integers bounded by the kind's range above and
## never calls this. Both branches are bit-deterministic and agree on their
## overlap: the integer branch is exact Newton's-method floor(sqrt), and the
## float64 fallback (used only when an axis delta could overflow an int64
## square, i.e. absurd out-of-range distances) converts exact int64 values
## (< 2^53) and floors the correctly-rounded IEEE sqrt.
static func _distance_micro(dx: int, dy: int) -> int:
	const INT_AXIS_LIMIT := 2_147_000_000
	if absi(dx) <= INT_AXIS_LIMIT and absi(dy) <= INT_AXIS_LIMIT:
		return _isqrt(dx * dx + dy * dy)
	return int(floor(sqrt(float(dx) * float(dx) + float(dy) * float(dy))))


## Deterministic floor(sqrt(value)) via integer-only Newton's method; `value`
## must be non-negative and below the int64 square of INT_AXIS_LIMIT*sqrt(2).
static func _isqrt(value: int) -> int:
	if value <= 0:
		return 0
	var x := value
	var y := (x + 1) / 2
	while y < x:
		x = y
		y = (x + value / x) / 2
	return x