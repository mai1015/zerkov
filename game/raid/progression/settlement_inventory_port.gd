class_name SettlementInventoryPort
extends RefCounted
## Trusted root-only native inventory boundary. A base port cannot deploy.
func validate_loadout(_record: PackedByteArray) -> bool:
	return false

## Return a new persistence record, never mutate the live raid or profile.
## Required result: {ok, record, retained, lost}; retained/lost are grouped
## definition/quantity records, derived from native before/after snapshots.
func plan(_record: PackedByteArray, _outcome: String) -> Dictionary:
	return {"ok": false, "reason": &"settlement_inventory_unavailable"}

func validate_stash(_record: PackedByteArray) -> bool:
	return false
