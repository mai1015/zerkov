extends RefCounted
## Session-only sample world and crafting queue; not a production queue owner.

static func initialize(state: Dictionary) -> void:
	var worlds: Array = state.get("frontflow_worlds", [])
	var selected: int = int(state.get("frontflow_selected_world", 0))
	if selected >= 0 and selected < worlds.size():
		state["bunker_privacy"] = str(worlds[selected].get("privacy", state.get("bunker_privacy", "INVITE ONLY"))).to_upper()
	if not state.has("bunker_privacy"):
		state["bunker_privacy"] = "INVITE ONLY"
	if not state.has("bunker_code"):
		state["bunker_code"] = "ZK-7F2Q"
	if not state.has("bunker_guest_present"):
		state["bunker_guest_present"] = true
	if not state.has("bunker_queue_seeded"):
		var now: int = Time.get_ticks_msec()
		state["bunker_craft_queue"] = [
			{"id": "bandage", "name": "Bandage ×4", "asset": "item_bottle.png", "started_at": now - 218632, "finish_at": now + 134000, "duration": 352632, "claimed": false},
			{"id": "splint", "name": "Splint ×1", "asset": "item_tape.png", "started_at": now - 90000, "finish_at": now - 1, "duration": 90000, "claimed": false}
		]
		state["bunker_queue_seeded"] = true
	if not state.has("bunker_craft_queue"):
		state["bunker_craft_queue"] = []

