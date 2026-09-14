class_name ZInteractionResult
extends RefCounted
## Task 3.8 -- typed outcome of an interaction-policy evaluation.
##
## Never a bare bool: a denial always carries one specific machine-readable
## `reason` plus the resolved distance in canonical (Vision) microunits, so
## callers can surface exactly why an interaction was refused. `distance_micro`
## is `-1` only when no distance could be resolved at all (unknown target or
## an unconvertible position); an out-of-range/blocked/ineligible denial
## always reports the real resolved distance.

const REASON_NONE: StringName = &""
const REASON_OUT_OF_RANGE: StringName = &"out_of_range"
const REASON_LINE_BLOCKED: StringName = &"line_blocked"
const REASON_UNKNOWN_TARGET: StringName = &"unknown_target"
const REASON_INELIGIBLE: StringName = &"ineligible"
const REASON_WRONG_KIND: StringName = &"wrong_kind"
const REASON_GENERATION_STALE: StringName = &"generation_stale"
const REASON_INVALID_REQUEST: StringName = &"invalid_request"
## The named actor has no authoritative resolved position available to the
## evaluator (unknown actor, or no movement-world body and no injected
## position). Only `ZInteractionPolicyOwner` produces this reason; the pure
## policy always receives a concrete request position.
const REASON_ACTOR_UNKNOWN: StringName = &"actor_unknown"

var allowed: bool = false
var reason: StringName = REASON_NONE
var target_id: StringName = &""
var kind: StringName = &""
var distance_micro: int = -1


static func allow(
	p_target_id: StringName,
	p_kind: StringName,
	p_distance_micro: int
) -> ZInteractionResult:
	var result := ZInteractionResult.new()
	result.allowed = true
	result.reason = REASON_NONE
	result.target_id = p_target_id
	result.kind = p_kind
	result.distance_micro = p_distance_micro
	return result


static func deny(
	p_reason: StringName,
	p_target_id: StringName,
	p_kind: StringName,
	p_distance_micro: int = -1
) -> ZInteractionResult:
	var result := ZInteractionResult.new()
	result.allowed = false
	result.reason = p_reason
	result.target_id = p_target_id
	result.kind = p_kind
	result.distance_micro = p_distance_micro
	return result


func canonical_record() -> Dictionary:
	return {
		"allowed": allowed,
		"distance_micro": distance_micro,
		"kind": String(kind),
		"reason": String(reason),
		"target_id": String(target_id),
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())


func is_equal_to(other: ZInteractionResult) -> bool:
	return other != null \
		and allowed == other.allowed \
		and reason == other.reason \
		and target_id == other.target_id \
		and kind == other.kind \
		and distance_micro == other.distance_micro
