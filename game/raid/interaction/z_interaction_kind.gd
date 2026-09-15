class_name ZInteractionKind
extends RefCounted
## Task 3.8 -- the closed set of first-playable interaction target kinds.
##
## Each kind carries its own explicit bounded range and eligibility rule in
## `ZInteractionPolicy`; nothing here (or downstream) may substitute one
## shared/global radius or predicate for another kind.

const DOOR: StringName = &"door"
const CRATE: StringName = &"crate"
const CORPSE: StringName = &"corpse"
const HEAL_TARGET: StringName = &"heal_target"
const EXTRACTION_ZONE: StringName = &"extraction_zone"

const ALL: Array[StringName] = [DOOR, CRATE, CORPSE, HEAL_TARGET, EXTRACTION_ZONE]


static func is_valid(kind: StringName) -> bool:
	return ALL.has(kind)
