#include "resources/common_ui_device_profile.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void CommonUIDeviceProfile::set_family_id(const StringName &p_family_id) {
	family_id = p_family_id;
	emit_changed();
}

void CommonUIDeviceProfile::set_name_patterns(const PackedStringArray &p_patterns) {
	name_patterns = p_patterns;
	emit_changed();
}

void CommonUIDeviceProfile::set_glyph_map(const Dictionary &p_glyph_map) {
	glyph_map = p_glyph_map;
	emit_changed();
}

void CommonUIDeviceProfile::set_fallback_glyph_id(const StringName &p_glyph_id) {
	fallback_glyph_id = p_glyph_id;
	emit_changed();
}

bool CommonUIDeviceProfile::matches_device_name(const String &p_device_name) const {
	const String lowered = p_device_name.to_lower();
	for (int i = 0; i < name_patterns.size(); ++i) {
		const String pattern = name_patterns[i].to_lower();
		if (!pattern.is_empty() && lowered.contains(pattern)) {
			return true;
		}
	}
	return false;
}

StringName CommonUIDeviceProfile::resolve_glyph(const Ref<CommonUIBinding> &p_binding) const {
	if (p_binding.is_null()) {
		return fallback_glyph_id;
	}
	const String key = itos(static_cast<int>(p_binding->get_device_kind())) + ":" +
			itos(p_binding->get_code());
	if (glyph_map.has(key)) {
		return StringName(glyph_map[key]);
	}
	// A binding may carry its own identifier for a device-agnostic glyph.
	if (!String(p_binding->get_glyph_id()).is_empty()) {
		return p_binding->get_glyph_id();
	}
	return fallback_glyph_id;
}

void CommonUIDeviceProfile::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_family_id", "family_id"), &CommonUIDeviceProfile::set_family_id);
	ClassDB::bind_method(D_METHOD("get_family_id"), &CommonUIDeviceProfile::get_family_id);
	ClassDB::bind_method(D_METHOD("set_name_patterns", "patterns"), &CommonUIDeviceProfile::set_name_patterns);
	ClassDB::bind_method(D_METHOD("get_name_patterns"), &CommonUIDeviceProfile::get_name_patterns);
	ClassDB::bind_method(D_METHOD("set_glyph_map", "glyph_map"), &CommonUIDeviceProfile::set_glyph_map);
	ClassDB::bind_method(D_METHOD("get_glyph_map"), &CommonUIDeviceProfile::get_glyph_map);
	ClassDB::bind_method(D_METHOD("set_fallback_glyph_id", "glyph_id"),
			&CommonUIDeviceProfile::set_fallback_glyph_id);
	ClassDB::bind_method(D_METHOD("get_fallback_glyph_id"), &CommonUIDeviceProfile::get_fallback_glyph_id);
	ClassDB::bind_method(D_METHOD("matches_device_name", "device_name"),
			&CommonUIDeviceProfile::matches_device_name);
	ClassDB::bind_method(D_METHOD("resolve_glyph", "binding"), &CommonUIDeviceProfile::resolve_glyph);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "family_id"), "set_family_id", "get_family_id");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "name_patterns"), "set_name_patterns",
			"get_name_patterns");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "glyph_map"), "set_glyph_map", "get_glyph_map");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "fallback_glyph_id"), "set_fallback_glyph_id",
			"get_fallback_glyph_id");
}

} // namespace godot
