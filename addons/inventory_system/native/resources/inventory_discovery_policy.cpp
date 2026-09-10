#include "resources/inventory_discovery_policy.h"

#include "core/inv_limits.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryDiscoveryPolicy::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_container_search_instant(bool p_instant) {
	container_search_instant = p_instant;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_container_search_duration_ms(int p_duration_ms) {
	container_search_duration_ms = p_duration_ms;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_item_scan_instant(bool p_instant) {
	item_scan_instant = p_instant;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_item_scan_duration_ms(int p_duration_ms) {
	item_scan_duration_ms = p_duration_ms;
	emit_changed();
}

void InventoryDiscoveryPolicy::set_shell_label(const String &p_shell_label) {
	shell_label = p_shell_label;
	emit_changed();
}

void InventoryDiscoveryPolicy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryDiscoveryPolicy::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryDiscoveryPolicy::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &InventoryDiscoveryPolicy::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &InventoryDiscoveryPolicy::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_container_search_instant", "instant"), &InventoryDiscoveryPolicy::set_container_search_instant);
	ClassDB::bind_method(D_METHOD("get_container_search_instant"), &InventoryDiscoveryPolicy::get_container_search_instant);
	ClassDB::bind_method(D_METHOD("set_container_search_duration_ms", "duration_ms"), &InventoryDiscoveryPolicy::set_container_search_duration_ms);
	ClassDB::bind_method(D_METHOD("get_container_search_duration_ms"), &InventoryDiscoveryPolicy::get_container_search_duration_ms);
	ClassDB::bind_method(D_METHOD("set_item_scan_instant", "instant"), &InventoryDiscoveryPolicy::set_item_scan_instant);
	ClassDB::bind_method(D_METHOD("get_item_scan_instant"), &InventoryDiscoveryPolicy::get_item_scan_instant);
	ClassDB::bind_method(D_METHOD("set_item_scan_duration_ms", "duration_ms"), &InventoryDiscoveryPolicy::set_item_scan_duration_ms);
	ClassDB::bind_method(D_METHOD("get_item_scan_duration_ms"), &InventoryDiscoveryPolicy::get_item_scan_duration_ms);
	ClassDB::bind_method(D_METHOD("set_shell_label", "shell_label"), &InventoryDiscoveryPolicy::set_shell_label);
	ClassDB::bind_method(D_METHOD("get_shell_label"), &InventoryDiscoveryPolicy::get_shell_label);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.discovery.world_chest"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version"), "set_schema_version", "get_schema_version");

	ADD_GROUP("Container Search", "container_search_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "container_search_instant"),
			"set_container_search_instant", "get_container_search_instant");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "container_search_duration_ms", PROPERTY_HINT_RANGE,
						 vformat("0,%u,1,or_greater", inv::MAX_DISCOVERY_DURATION_MS)),
			"set_container_search_duration_ms", "get_container_search_duration_ms");

	ADD_GROUP("Item Scan", "item_scan_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "item_scan_instant"),
			"set_item_scan_instant", "get_item_scan_instant");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "item_scan_duration_ms", PROPERTY_HINT_RANGE,
						 vformat("0,%u,1,or_greater", inv::MAX_DISCOVERY_DURATION_MS)),
			"set_item_scan_duration_ms", "get_item_scan_duration_ms");

	ADD_GROUP("Disclosure", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "shell_label", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "Sealed crate"),
			"set_shell_label", "get_shell_label");
}

} // namespace godot
