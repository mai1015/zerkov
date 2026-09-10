#ifndef COMMON_UI_DEVICE_PROFILE_H
#define COMMON_UI_DEVICE_PROFILE_H

#include "resources/common_ui_binding.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Maps a controller family to logical glyph identifiers.
//
// The profile resolves identifiers only. Turning an identifier into a texture,
// SVG, animation, or localized string is the presentation layer's job.
class CommonUIDeviceProfile : public Resource {
	GDCLASS(CommonUIDeviceProfile, Resource)

public:
	void set_family_id(const StringName &p_family_id);
	StringName get_family_id() const { return family_id; }

	// Substrings matched case-insensitively against the joypad name reported by
	// the platform. The first profile with a match wins.
	void set_name_patterns(const PackedStringArray &p_patterns);
	PackedStringArray get_name_patterns() const { return name_patterns; }

	// Maps "<device_kind>:<code>" to a logical glyph identifier.
	void set_glyph_map(const Dictionary &p_glyph_map);
	Dictionary get_glyph_map() const { return glyph_map; }

	// Returned when the map has no entry for a binding on this family.
	void set_fallback_glyph_id(const StringName &p_glyph_id);
	StringName get_fallback_glyph_id() const { return fallback_glyph_id; }

	bool matches_device_name(const String &p_device_name) const;

	// Logical glyph identifier for p_binding, or the fallback. Returns an empty
	// StringName only when neither is configured.
	StringName resolve_glyph(const Ref<CommonUIBinding> &p_binding) const;

protected:
	static void _bind_methods();

private:
	StringName family_id;
	PackedStringArray name_patterns;
	Dictionary glyph_map;
	StringName fallback_glyph_id;
};

} // namespace godot

#endif // COMMON_UI_DEVICE_PROFILE_H
