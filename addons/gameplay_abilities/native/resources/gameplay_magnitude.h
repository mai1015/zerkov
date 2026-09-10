#ifndef GAMEPLAY_ABILITIES_RESOURCES_MAGNITUDE_H
#define GAMEPLAY_ABILITIES_RESOURCES_MAGNITUDE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::MagnitudeSourceDesc`
// (native/core/ga_effects.h). Resolution is always `coefficient * raw_value`;
// `raw_value` depends on `kind` exactly as documented there:
//   CONSTANT          -> 1 (resolved value is simply `coefficient`)
//   ABILITY_LEVEL     -> the applying spec's level, as a whole number
//   SOURCE_ATTRIBUTE  -> the source entity's current value of `attribute`
//   TARGET_ATTRIBUTE  -> the target entity's current value of `attribute`
//   SET_BY_CALLER     -> the caller-supplied magnitude for `set_by_caller_field`
class GameplayMagnitude : public Resource {
	GDCLASS(GameplayMagnitude, Resource)

public:
	enum Kind {
		KIND_CONSTANT = 0,
		KIND_ABILITY_LEVEL = 1,
		KIND_SOURCE_ATTRIBUTE = 2,
		KIND_TARGET_ATTRIBUTE = 3,
		KIND_SET_BY_CALLER = 4,
	};

	void set_kind(Kind p_kind);
	Kind get_kind() const { return kind; }

	void set_coefficient(double p_coefficient);
	double get_coefficient() const { return coefficient; }

	// Only meaningful for KIND_SOURCE_ATTRIBUTE / KIND_TARGET_ATTRIBUTE.
	void set_attribute(const StringName &p_attribute);
	StringName get_attribute() const { return attribute; }

	// Only meaningful for KIND_SET_BY_CALLER; must name a field the owning
	// effect declares (see `GameplaySetByCallerField`).
	void set_set_by_caller_field(const StringName &p_field);
	StringName get_set_by_caller_field() const { return set_by_caller_field; }

protected:
	static void _bind_methods();
	// Hides `attribute`/`set_by_caller_field` unless the selected `kind`
	// actually uses them.
	void _validate_property(PropertyInfo &p_property) const;

private:
	Kind kind = KIND_CONSTANT;
	double coefficient = 1.0;
	StringName attribute;
	StringName set_by_caller_field;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayMagnitude::Kind);

#endif // GAMEPLAY_ABILITIES_RESOURCES_MAGNITUDE_H
