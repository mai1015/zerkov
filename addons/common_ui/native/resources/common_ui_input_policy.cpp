#include "resources/common_ui_input_policy.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void CommonUIInputPolicy::set_mouse_jitter_threshold(double p_pixels) {
	mouse_jitter_threshold = p_pixels < 0.0 ? 0.0 : p_pixels;
	emit_changed();
}

void CommonUIInputPolicy::set_stick_dead_zone(double p_dead_zone) {
	stick_dead_zone = CLAMP(p_dead_zone, 0.0, 1.0);
	emit_changed();
}

void CommonUIInputPolicy::set_modality_hysteresis(double p_seconds) {
	modality_hysteresis = p_seconds < 0.0 ? 0.0 : p_seconds;
	emit_changed();
}

void CommonUIInputPolicy::set_mouse_motion_decay(double p_seconds) {
	mouse_motion_decay = p_seconds < 0.0 ? 0.0 : p_seconds;
	emit_changed();
}

void CommonUIInputPolicy::set_mouse_button_always_activates(bool p_enabled) {
	mouse_button_always_activates = p_enabled;
	emit_changed();
}

void CommonUIInputPolicy::set_unassigned_devices_use_default_user(bool p_enabled) {
	unassigned_devices_use_default_user = p_enabled;
	emit_changed();
}

void CommonUIInputPolicy::set_shared_device_policy(bool p_enabled) {
	shared_device_policy = p_enabled;
	emit_changed();
}

void CommonUIInputPolicy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_mouse_jitter_threshold", "pixels"),
			&CommonUIInputPolicy::set_mouse_jitter_threshold);
	ClassDB::bind_method(D_METHOD("get_mouse_jitter_threshold"),
			&CommonUIInputPolicy::get_mouse_jitter_threshold);
	ClassDB::bind_method(D_METHOD("set_stick_dead_zone", "dead_zone"),
			&CommonUIInputPolicy::set_stick_dead_zone);
	ClassDB::bind_method(D_METHOD("get_stick_dead_zone"), &CommonUIInputPolicy::get_stick_dead_zone);
	ClassDB::bind_method(D_METHOD("set_modality_hysteresis", "seconds"),
			&CommonUIInputPolicy::set_modality_hysteresis);
	ClassDB::bind_method(D_METHOD("get_modality_hysteresis"),
			&CommonUIInputPolicy::get_modality_hysteresis);
	ClassDB::bind_method(D_METHOD("set_mouse_motion_decay", "seconds"),
			&CommonUIInputPolicy::set_mouse_motion_decay);
	ClassDB::bind_method(D_METHOD("get_mouse_motion_decay"),
			&CommonUIInputPolicy::get_mouse_motion_decay);
	ClassDB::bind_method(D_METHOD("set_mouse_button_always_activates", "enabled"),
			&CommonUIInputPolicy::set_mouse_button_always_activates);
	ClassDB::bind_method(D_METHOD("is_mouse_button_always_activating"),
			&CommonUIInputPolicy::is_mouse_button_always_activating);
	ClassDB::bind_method(D_METHOD("set_unassigned_devices_use_default_user", "enabled"),
			&CommonUIInputPolicy::set_unassigned_devices_use_default_user);
	ClassDB::bind_method(D_METHOD("are_unassigned_devices_using_default_user"),
			&CommonUIInputPolicy::are_unassigned_devices_using_default_user);
	ClassDB::bind_method(D_METHOD("set_shared_device_policy", "enabled"),
			&CommonUIInputPolicy::set_shared_device_policy);
	ClassDB::bind_method(D_METHOD("is_shared_device_policy_enabled"),
			&CommonUIInputPolicy::is_shared_device_policy_enabled);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mouse_jitter_threshold", PROPERTY_HINT_RANGE,
						 "0.0,64.0,0.5,or_greater"),
			"set_mouse_jitter_threshold", "get_mouse_jitter_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stick_dead_zone", PROPERTY_HINT_RANGE, "0.0,1.0,0.01"),
			"set_stick_dead_zone", "get_stick_dead_zone");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "modality_hysteresis", PROPERTY_HINT_RANGE,
						 "0.0,2.0,0.01,or_greater"),
			"set_modality_hysteresis", "get_modality_hysteresis");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mouse_motion_decay", PROPERTY_HINT_RANGE,
						 "0.0,5.0,0.01,or_greater"),
			"set_mouse_motion_decay", "get_mouse_motion_decay");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "mouse_button_always_activates"),
			"set_mouse_button_always_activates", "is_mouse_button_always_activating");
	ADD_GROUP("UI Users", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "unassigned_devices_use_default_user"),
			"set_unassigned_devices_use_default_user", "are_unassigned_devices_using_default_user");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shared_device_policy"), "set_shared_device_policy",
			"is_shared_device_policy_enabled");
}

} // namespace godot
