#ifndef GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TRIGGER_H
#define GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TRIGGER_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::AbilityTriggerDesc`
// (native/core/ga_abilities.h): one entry in `GameplayAbilityDefinition`'s
// `triggers` list. This is intentionally a tiny standalone Resource (rather
// than an inline Dictionary), mirroring the same `GameplayTagOperand` /
// `GameplayModifierDeclaration` precedent already established for other
// per-declaration array elements.
//
// `input_id` is an opaque, game-defined logical action name (e.g.
// "action.dash") -- never a Godot `InputEvent`, and never registered,
// consumed, or rebound by this addon (design.md "Input-Agnostic Activation
// API"). `gameplay_event_tag` must name a tag registered in the same
// validated asset set; `GameplayDefinitionValidator` resolves it.
class GameplayAbilityTrigger : public Resource {
	GDCLASS(GameplayAbilityTrigger, Resource)

public:
	enum Kind {
		KIND_INPUT = 0,
		KIND_GAMEPLAY_EVENT = 1,
	};

	void set_kind(Kind p_kind);
	Kind get_kind() const { return kind; }

	// Only meaningful for KIND_INPUT.
	void set_input_id(const String &p_input_id);
	String get_input_id() const { return input_id; }

	// Only meaningful for KIND_GAMEPLAY_EVENT; must name a registered tag.
	void set_gameplay_event_tag(const StringName &p_tag);
	StringName get_gameplay_event_tag() const { return gameplay_event_tag; }

protected:
	static void _bind_methods();
	// Hides `input_id`/`gameplay_event_tag` unless the selected `kind`
	// actually uses them.
	void _validate_property(PropertyInfo &p_property) const;

private:
	Kind kind = KIND_INPUT;
	String input_id;
	StringName gameplay_event_tag;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityTrigger::Kind);

#endif // GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TRIGGER_H
