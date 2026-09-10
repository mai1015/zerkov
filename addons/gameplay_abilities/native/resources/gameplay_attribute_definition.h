#ifndef GAMEPLAY_ABILITIES_RESOURCES_ATTRIBUTE_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_ATTRIBUTE_DEFINITION_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::AttributeDefinition` /
// `AttributeRegistry::register_attribute` (native/core/ga_attributes.h).
//
// `default_base`, `min_value`, and `max_value` are plain decimals here --
// exactly the representation `ga::fixed_quantize` documents as the ONE
// place a `double` may enter authoritative state. `GameplayDefinitionValidator`
// is the only code that calls `fixed_quantize` on these fields; this class
// never formats or re-derives a fixed-point value itself.
class GameplayAttributeDefinition : public Resource {
	GDCLASS(GameplayAttributeDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_default_base(double p_value);
	double get_default_base() const { return default_base; }

	void set_has_min(bool p_has_min);
	bool get_has_min() const { return has_min; }

	void set_min_value(double p_value);
	double get_min_value() const { return min_value; }

	void set_has_max(bool p_has_max);
	bool get_has_max() const { return has_max; }

	void set_max_value(double p_value);
	double get_max_value() const { return max_value; }

	void set_display_name(const String &p_display_name);
	String get_display_name() const { return display_name; }

protected:
	static void _bind_methods();
	// Hides min_value/max_value when their respective has_* toggle is off, so
	// the inspector never suggests they are meaningful when they are not
	// authored at all (see `ga::AttributeDefinition::has_min`/`has_max`).
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	double default_base = 0.0;
	bool has_min = false;
	double min_value = 0.0;
	bool has_max = false;
	double max_value = 0.0;
	String display_name;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_ATTRIBUTE_DEFINITION_H
