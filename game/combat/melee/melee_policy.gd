class_name ZMeleePolicy
extends RefCounted
## Game-owned melee data shared by content, execution, and tests. Integer ticks,
## Weapon milliunits for damage/range; GAS microunits for resource costs.
const MACHETE_DAMAGE: int = 55_000
const MACHETE_REACH: int = 1_750
const MACHETE_RADIUS: int = 350
const MACHETE_WINDUP: int = 10
const MACHETE_ACTIVE: int = 3
const MACHETE_RECOVERY: int = 18
const MACHETE_COST: int = 175_000

static func definition(archetype: StringName) -> Dictionary:
	var result: Dictionary = {}
	match archetype:
		&"machete":
			result = {"id": "zerkov.weapon.machete", "damage_milliunits": MACHETE_DAMAGE,
				"reach_raw": MACHETE_REACH * 1000, "radius_raw": MACHETE_RADIUS * 1000,
				"windup_ticks": MACHETE_WINDUP, "active_ticks": MACHETE_ACTIVE,
				"recovery_ticks": MACHETE_RECOVERY, "cost_micros": MACHETE_COST}
		&"mutant":
			# A natural attack, not an Inventory item or Weapon System firearm.
			result = {"id": "zerkov.attack.mutant.claw", "damage_milliunits": 25_000,
				"reach_raw": 1_250_000, "radius_raw": 300_000,
				"windup_ticks": 12, "active_ticks": 3, "recovery_ticks": 30,
				"cost_micros": 0}
	result.make_read_only()
	return result
