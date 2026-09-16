class_name LocalCharacterRuntime
extends CharacterUIRuntime
## Reuses the accepted workspace; root-selected containers remain actual native
## inventory identities, never fixture data or screen-owned inventory state.
func _init() -> void:
	_controller = LocalInventoryController.new()

## An explicit world-open also selects the visible loot tab. Opening only the
## controller would leave a newly mounted screen on its retained stash tab.
func open_world_loot(source: StringName, inventory_id: int) -> bool:
	var controller := _controller as LocalInventoryController
	if not is_configured() or controller == null \
		or not controller.bind_world_inventory(source, inventory_id) \
		or not controller.set_loot_container(source) or not controller.open_loot_container():
		return false
	var state := interaction_state()
	state["loot_mode"] = true
	state["loot_open"] = true
	state["live_tab"] = "gear"
	state["current_filter"] = "all"
	state["search_query"] = ""
	state["selected_item"] = {}
	state["selected_source"] = ""
	save_interaction_state(state)
	return true
