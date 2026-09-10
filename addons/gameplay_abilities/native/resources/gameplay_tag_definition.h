#ifndef GAMEPLAY_ABILITIES_RESOURCES_TAG_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_TAG_DEFINITION_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::TagDefinitionDesc` (native/core/ga_tags.h).
//
// This resource is deliberately just data: identifier, description, and an
// authoring-origin label. Parent relationships, registration, sealing, and
// duplicate/collision detection all happen in the core `ga::TagRegistry` --
// never re-implemented here -- via `GameplayDefinitionValidator`
// (native/godot/gameplay_definition_validator.h), which is the only place
// authored tag resources are actually validated and interned.
class GameplayTagDefinition : public Resource {
	GDCLASS(GameplayTagDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_description(const String &p_description);
	String get_description() const { return description; }

	// Names the authoring resource/origin purely for duplicate-conflict
	// diagnostics (see `ga::TagDefinitionDesc::source_label`). Left empty, the
	// validator falls back to this resource's own path.
	void set_source_label(const String &p_source_label);
	String get_source_label() const { return source_label; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	String description;
	String source_label;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_TAG_DEFINITION_H
