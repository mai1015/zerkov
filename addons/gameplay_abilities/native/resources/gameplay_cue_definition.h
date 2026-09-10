#ifndef GAMEPLAY_ABILITIES_RESOURCES_CUE_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_CUE_DEFINITION_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// A logical cue identity, referenced by identifier from
// `GameplayEffectDefinition::cue_identifiers` and registered into the core
// `ga::EffectRegistry` via `register_cue` (native/core/ga_effects.h) by
// `GameplayDefinitionValidator`.
//
// This resource carries no presentation framework, no VFX/audio/animation
// reference, and no scene node -- only the stable identifier and bounded,
// purely descriptive metadata a game's own HUD/animation/VFX/audio adapters
// may read to decide what to play. See design.md "Godot resource, scene, and
// presentation boundary": the addon emits logical cue events but never owns
// presentation.
class GameplayCueDefinition : public Resource {
	GDCLASS(GameplayCueDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_display_name(const String &p_display_name);
	String get_display_name() const { return display_name; }

	void set_description(const String &p_description);
	String get_description() const { return description; }

	// Free-form logical grouping a presentation adapter may switch on (e.g.
	// "vfx", "audio", "hud", "animation"). Never a framework/resource
	// reference -- see class comment.
	void set_category(const StringName &p_category);
	StringName get_category() const { return category; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	String display_name;
	String description;
	StringName category;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_CUE_DEFINITION_H
