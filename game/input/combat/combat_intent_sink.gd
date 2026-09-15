class_name ZCombatIntentSink
extends RefCounted
## Root-owned queue admission port, not a gameplay executor. Production uses
## RaidCombatIntentSink. Explicit test doubles use the real ZRaidIntentQueue.

func context() -> Dictionary:
	return {}


func admit(_intent: ZRaidIntent) -> Dictionary:
	return {"admitted": false, "reason": &"combat_sink_unbound"}
