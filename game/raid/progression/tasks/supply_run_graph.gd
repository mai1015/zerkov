class_name SupplyRunGraph
extends RefCounted
## Authored native Level Task definition, not a second quest executor.
const ID: String = "zerkov.task.supply_run"
const CRATES: Array[String] = ["zerkov.loot.sawmill.crate.log_racks", "zerkov.loot.sawmill.crate.saw_house", "zerkov.loot.sawmill.crate.settling_dock"]
const ROAD_GATE: String = "zerkov.extract.sawmill.road_gate"
## Closed authored map vocabulary. Default identifiers preserve existing saves
## and tests; native maps cannot accidentally complete another map's objective.
static func is_map(map_id: String) -> bool:
	return map_id in ["sawmill", "northline", "blackwater"]

static func crates_for(map_id: String = "sawmill") -> Array[String]:
	if map_id == "sawmill": return CRATES.duplicate()
	if not is_map(map_id): return []
	return ["zerkov.loot."+map_id+".crate.a", "zerkov.loot."+map_id+".crate.b", "zerkov.loot."+map_id+".crate.c"]

static func exit_for(map_id: String = "sawmill") -> String:
	if map_id == "sawmill": return ROAD_GATE
	return "zerkov.extract."+map_id+".road_gate" if is_map(map_id) else ""

static func title_for(map_id: String = "sawmill") -> String:
	return {"sawmill":"Sawmill Yard", "northline":"Northline Exclusion Zone", "blackwater":"Blackwater Crossing"}.get(map_id, "Unavailable map")

static func exit_title(map_id: String = "sawmill") -> String:
	return {"sawmill":"Road Gate", "northline":"West Service", "blackwater":"East Road"}.get(map_id, "Unavailable exit")

static func crate_titles(map_id: String = "sawmill") -> Array[String]:
	if map_id == "northline": return ["Checkpoint supplies", "Freight cargo", "Rail loading crate"]
	if map_id == "blackwater": return ["Customs supplies", "East road salvage", "Records case"]
	return ["Log Racks crate", "Saw House crate", "Settling Dock crate"]

static func task_id(map_id: String = "sawmill") -> String:
	return ID if map_id == "sawmill" else "zerkov.task."+map_id+".supply_run"

static func accepts_target(key: String) -> bool:
	for map_id: String in ["sawmill", "northline", "blackwater"]:
		if crates_for(map_id).has(key) or exit_for(map_id)==key: return true
	return false

static func definition(map_id: String = "sawmill") -> Dictionary:
	if not is_map(map_id): return {}
	var nodes: Array = [
		{"identifier":"entry","kind":0},
		{"identifier":"accept","kind":5,"provider_identifier":"zerkov.host.accept_supply_run"},
		{"identifier":"crates","kind":3,"ports":[
			{"identifier":"a","direction":0,"value_type":0,"required":true},
			{"identifier":"b","direction":0,"value_type":0,"required":true},
			{"identifier":"c","direction":0,"value_type":0,"required":true}]},
		{"identifier":"extract","kind":5,"provider_identifier":"zerkov.host.extract_road_gate"},
		{"identifier":"reward","kind":8,"provider_identifier":"zerkov.host.complete_supply_run"},
		{"identifier":"death","kind":1,"provider_identifier":"zerkov.event.raid_failed","objective_target":1},
		{"identifier":"done","kind":9,"outcome_identifier":"success"},
		{"identifier":"failed","kind":10,"outcome_identifier":"failure"},
		{"identifier":"declined","kind":10,"outcome_identifier":"failure"},
		{"identifier":"denied","kind":10,"outcome_identifier":"failure"},
	]
	var edges: Array = [_edge("entry","entry","accept","input"),
		_edge("accept","accepted","death","input"), _edge("accept","rejected","declined","input"),
		_edge("crates","all","extract","input"), _edge("extract","accepted","reward","input"),
		_edge("reward","accepted","done","input"), _edge("reward","rejected","denied","input"),
		_edge("death","success","failed","input")]
	for i in range(3):
		var id := "crate_" + str(i)
		nodes.append({"identifier":id,"kind":1,"provider_identifier":"zerkov.event."+id,"objective_target":1})
		edges.append(_edge("accept","accepted",id,"input"))
		edges.append(_edge(id,"success","crates",["a","b","c"][i]))
	return {"identifier":task_id(map_id),"entry_node_identifier":"entry","terminal_outcomes":["success","failure"],"nodes":nodes,"edges":edges}
static func _edge(a: String, port: String, b: String, input: String) -> Dictionary:
	return {"identifier":a+"_"+b,"from_node_identifier":a,"from_port_identifier":port,"to_node_identifier":b,"to_port_identifier":input}
