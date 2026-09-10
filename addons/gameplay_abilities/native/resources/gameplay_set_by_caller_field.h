#ifndef GAMEPLAY_ABILITIES_RESOURCES_SET_BY_CALLER_FIELD_H
#define GAMEPLAY_ABILITIES_RESOURCES_SET_BY_CALLER_FIELD_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::SetByCallerFieldDesc`
// (native/core/ga_effects.h): one named magnitude parameter an effect
// declares (e.g. "heal_amount"). This is a lightweight single-segment name,
// not a namespaced content identifier -- it is only ever matched against the
// SAME effect's own declaration, never registered in a shared registry (see
// the core header's comment on `SetByCallerFieldDesc`).
class GameplaySetByCallerField : public Resource {
	GDCLASS(GameplaySetByCallerField, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_required(bool p_required);
	bool is_required() const { return required; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	bool required = false;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_SET_BY_CALLER_FIELD_H
