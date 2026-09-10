#ifndef GAMEPLAY_ABILITIES_RESOURCES_TAG_OPERAND_H
#define GAMEPLAY_ABILITIES_RESOURCES_TAG_OPERAND_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// One leaf term of an authored tag-query clause: a tag identifier plus how it
// must be matched against a container. Mirrors `ga::TagQueryOperand` /
// `ga::TagOperandDesc` (native/core/ga_tag_query.h, ga_effects.h) exactly, so
// the validator's conversion to the core shape is a direct field copy.
//
// This is intentionally a tiny standalone Resource (rather than an inline
// Dictionary or a pair of parallel arrays) so it can be reused wherever an
// authored requirement lists operands: standalone `GameplayTagQueryResource`
// assets and the source/target/immunity requirement queries embedded in
// `GameplayEffectDefinition`.
class GameplayTagOperand : public Resource {
	GDCLASS(GameplayTagOperand, Resource)

public:
	enum MatchMode {
		// The container must own this exact tag; an ancestor or descendant
		// does not satisfy it.
		MATCH_EXACT = 0,
		// An owned descendant of this tag also satisfies it.
		MATCH_PARENT_AWARE = 1,
	};

	void set_tag(const StringName &p_tag);
	StringName get_tag() const { return tag; }

	void set_match_mode(MatchMode p_mode);
	MatchMode get_match_mode() const { return match_mode; }

protected:
	static void _bind_methods();

private:
	StringName tag;
	MatchMode match_mode = MATCH_EXACT;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayTagOperand::MatchMode);

#endif // GAMEPLAY_ABILITIES_RESOURCES_TAG_OPERAND_H
