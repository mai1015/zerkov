extends SceneTree
## Minimal independent 4.9 blocker reproduction using only public catalog/authority APIs.
const OUT := "res://docs/qa/inventory_weapon_reload/astra_gate/"
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func verify(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("ASTRA_MAGAZINE_PROBE: " + message)

func run() -> void:
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	verify(owner.configure(), "real approved catalog creates raid inventory")
	var inv := owner.raid_authority()
	var id := owner.raid_player_inventory_id
	var backpack := 0
	for container in inv.snapshot(id).get_containers():
		if container.get("provider_item") == 0 and container.get("container_definition_identifier") == String(ZerkovInventoryCatalog.CONTAINER_BACKPACK):
			backpack = int(container.get("id"))
	verify(backpack > 0, "empty root backpack resolves")
	var before := inv.inventory_revision(id)
	var insertion: Dictionary = inv.insert_item(id, String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM), 1,
		{"kind": "spatial", "container": backpack, "x": 0, "y": 0, "rotated": false}, 701, 1)
	verify(insertion.get("accepted", false), "AKM magazine must materialize its ammo container for the adapter's magazine-first source policy")
	var child_count := 0
	for container in inv.snapshot(id).get_containers():
		if container.get("container_definition_identifier") == String(ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM):
			child_count += 1
	verify(child_count == 1, "canonical magazine ammo container must exist")
	var result := {"checks": checks, "failures": failures, "human_approval": false,
		"inventory_revision_before": before, "inventory_revision_after": inv.inventory_revision(id),
		"magazine_insertion": insertion, "magazine_child_containers": child_count,
		"diagnostic_115": "NESTING_DEPTH_EXCEEDED", "expected_nested_depth": 1,
		"catalog_source": "game/content/zerkov_inventory_catalog.gd::_magazine_container",
		"native_source": "addons/inventory_system/native/core/inv_runtime_state.cpp:681"}
	print("ASTRA_MAGAZINE_NATIVE_RESULT ", JSON.stringify(insertion))
	verify(owner.teardown(owner.generation()), "exact owner teardown succeeds")
	owner.queue_free()
	await process_frame
	await process_frame
	result["checks"] = checks
	result["failures"] = failures
	var file := FileAccess.open(OUT+"magazine_probe_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")+"\n")
	file.close()
	print("ASTRA_MAGAZINE_PROBE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
