class_name ZRaidEvent
extends RefCounted
## One committed, ordered audit event.

enum EventKind {
	SPAWN,
	LOOT,
	FIRE,
	HIT,
	INJURY,
	HEAL,
	KILL,
	TASK,
	EXTRACTION,
	DEATH,
	SETTLEMENT,
}

const KIND_NAMES: PackedStringArray = [
	"spawn",
	"loot",
	"fire",
	"hit",
	"injury",
	"heal",
	"kill",
	"task",
	"extraction",
	"death",
	"settlement",
]

var event_id: ZConsequenceId
var raid_id: ZRaidId
var actor_id: ZEntityId
var kind: EventKind = EventKind.SPAWN
var tick: int = 0
var sequence: int = 0
var payload: Dictionary = {}


func canonical_record() -> Dictionary:
	return {
		"actor_id": actor_id.canonical_key() if actor_id != null else "",
		"event_id": event_id.canonical_key() if event_id != null else "",
		"kind": KIND_NAMES[int(kind)],
		"payload": payload.duplicate(true),
		"raid_id": raid_id.canonical_key() if raid_id != null else "",
		"sequence": sequence,
		"tick": tick,
	}
