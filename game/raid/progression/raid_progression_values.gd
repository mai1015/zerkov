class_name RaidProgressionValues
extends RefCounted
## Closed persistence values. No scene objects or executable data cross saves.
const STATE_KEY := "raid_progression"
const LOADOUT := "zerkov.inventory.loadout"
const STASH := "zerkov.inventory.stash"
const PENDING_LOADOUT := "zerkov.raid.pending_loadout"
const VERSION: int = 1
const MAX_HISTORY: int = 128 # Reserve a receipt slot BEFORE deploying, never evict silently.

static func digest(value: Variant) -> String:
	var encoded := ProfileCanonicalCodec.encode(value)
	return ProfileCanonicalCodec.sha256_domain("zerkov.raid.progression.v1", encoded.bytes) if encoded.ok else ""

static func encode(value: Variant) -> PackedByteArray:
	var result := ProfileCanonicalCodec.encode(value)
	return result.bytes if result.ok else PackedByteArray()

static func decode(bytes: PackedByteArray) -> Dictionary:
	var result := ProfileCanonicalCodec.decode(bytes)
	return result.value if result.ok and result.value is Dictionary else {}

static func freeze(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = freeze(value[key])
		result.make_read_only()
		return result
	if value is Array:
		var result: Array = []
		for child in value: result.append(freeze(child))
		result.make_read_only()
		return result
	if value is PackedByteArray: return value.duplicate()
	return value

static func failure(reason: StringName) -> Dictionary:
	return freeze({"ok": false, "reason": reason, "committed": false})

static func initial_state() -> Dictionary:
	return {"version": VERSION, "next_sequence": 1, "active": {}, "history": {}}

static func valid_state(state: Dictionary) -> bool:
	return state.size() == 4 and state.get("version") == VERSION \
		and typeof(state.get("next_sequence")) == TYPE_INT and state.next_sequence > 0 \
		and state.next_sequence < ProfileStore.MAX_COUNTER and state.get("active") is Dictionary \
		and state.get("history") is Dictionary and state.history.size() <= MAX_HISTORY

static func ids(profile_id: String, sequence: int) -> Dictionary:
	var suffix := profile_id.sha256_text().substr(0, 32) + ".r" + str(sequence)
	return {"raid_id": "zerkov.raid." + suffix, "settlement_id": "zerkov.settlement." + suffix}
