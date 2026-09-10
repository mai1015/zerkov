#ifndef INVENTORY_SYSTEM_RESOURCES_DISCOVERY_POLICY_H
#define INVENTORY_SYSTEM_RESOURCES_DISCOVERY_POLICY_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `inv::DiscoveryPolicyDefinition`. Like every
// other authoring Resource, this object remains editable; InventoryCatalog
// validates and copies its current values into immutable native catalog
// storage during registration.
class InventoryDiscoveryPolicy : public Resource {
	GDCLASS(InventoryDiscoveryPolicy, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }

	void set_container_search_instant(bool p_instant);
	bool get_container_search_instant() const { return container_search_instant; }

	void set_container_search_duration_ms(int p_duration_ms);
	int get_container_search_duration_ms() const { return container_search_duration_ms; }

	void set_item_scan_instant(bool p_instant);
	bool get_item_scan_instant() const { return item_scan_instant; }

	void set_item_scan_duration_ms(int p_duration_ms);
	int get_item_scan_duration_ms() const { return item_scan_duration_ms; }

	void set_shell_label(const String &p_shell_label);
	String get_shell_label() const { return shell_label; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = 1;
	bool container_search_instant = false;
	int container_search_duration_ms = 1000;
	bool item_scan_instant = false;
	int item_scan_duration_ms = 500;
	String shell_label;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_DISCOVERY_POLICY_H
