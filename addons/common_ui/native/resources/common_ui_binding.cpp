#include "resources/common_ui_binding.h"

#include <godot_cpp/classes/input_event_joypad_button.hpp>
#include <godot_cpp/classes/input_event_joypad_motion.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_screen_touch.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

void CommonUIBinding::set_device_kind(DeviceKind p_kind) {
	device_kind = p_kind;
	emit_changed();
	notify_property_list_changed();
}

void CommonUIBinding::set_slot(Slot p_slot) {
	slot = p_slot;
	emit_changed();
}

void CommonUIBinding::set_code(int p_code) {
	code = p_code;
	emit_changed();
}

void CommonUIBinding::set_axis_direction(AxisDirection p_direction) {
	axis_direction = p_direction;
	emit_changed();
}

void CommonUIBinding::set_dead_zone(float p_dead_zone) {
	// Godot's own action dead zone range; values outside it can never resolve.
	dead_zone = CLAMP(p_dead_zone, 0.0f, 1.0f);
	emit_changed();
}

void CommonUIBinding::set_shift_pressed(bool p_pressed) {
	shift_pressed = p_pressed;
	emit_changed();
}

void CommonUIBinding::set_ctrl_pressed(bool p_pressed) {
	ctrl_pressed = p_pressed;
	emit_changed();
}

void CommonUIBinding::set_alt_pressed(bool p_pressed) {
	alt_pressed = p_pressed;
	emit_changed();
}

void CommonUIBinding::set_meta_pressed(bool p_pressed) {
	meta_pressed = p_pressed;
	emit_changed();
}

void CommonUIBinding::set_glyph_id(const StringName &p_glyph_id) {
	glyph_id = p_glyph_id;
	emit_changed();
}

bool CommonUIBinding::is_valid_binding() const {
	switch (device_kind) {
		case DEVICE_KEYBOARD:
		case DEVICE_MOUSE:
			// Index 0 is KEY_NONE / MOUSE_BUTTON_NONE.
			return code > 0;
		case DEVICE_GAMEPAD_BUTTON:
			// JOY_BUTTON_A is 0, so zero is a legitimate button index.
			return code >= 0;
		case DEVICE_GAMEPAD_AXIS:
			// An axis binding without a direction cannot produce a press.
			return code >= 0 && axis_direction != AXIS_DIRECTION_NONE;
		case DEVICE_TOUCH:
			return true;
	}
	return false;
}

Ref<InputEvent> CommonUIBinding::to_input_event() const {
	switch (device_kind) {
		case DEVICE_KEYBOARD: {
			Ref<InputEventKey> event;
			event.instantiate();
			event->set_physical_keycode(static_cast<Key>(code));
			event->set_shift_pressed(shift_pressed);
			event->set_ctrl_pressed(ctrl_pressed);
			event->set_alt_pressed(alt_pressed);
			event->set_meta_pressed(meta_pressed);
			return event;
		}
		case DEVICE_MOUSE: {
			Ref<InputEventMouseButton> event;
			event.instantiate();
			event->set_button_index(static_cast<MouseButton>(code));
			event->set_shift_pressed(shift_pressed);
			event->set_ctrl_pressed(ctrl_pressed);
			event->set_alt_pressed(alt_pressed);
			event->set_meta_pressed(meta_pressed);
			return event;
		}
		case DEVICE_GAMEPAD_BUTTON: {
			Ref<InputEventJoypadButton> event;
			event.instantiate();
			event->set_button_index(static_cast<JoyButton>(code));
			return event;
		}
		case DEVICE_GAMEPAD_AXIS: {
			Ref<InputEventJoypadMotion> event;
			event.instantiate();
			event->set_axis(static_cast<JoyAxis>(code));
			event->set_axis_value(axis_direction == AXIS_DIRECTION_NEGATIVE ? -1.0f : 1.0f);
			return event;
		}
		case DEVICE_TOUCH: {
			Ref<InputEventScreenTouch> event;
			event.instantiate();
			event->set_index(code);
			return event;
		}
	}
	return Ref<InputEvent>();
}

String CommonUIBinding::get_signature() const {
	String signature = itos(static_cast<int>(device_kind)) + ":" + itos(code);
	if (device_kind == DEVICE_GAMEPAD_AXIS) {
		signature += ":" + itos(static_cast<int>(axis_direction));
	}
	if (device_kind == DEVICE_KEYBOARD || device_kind == DEVICE_MOUSE) {
		// Modifiers are part of the identity so Shift+Tab does not collide with
		// Tab during conflict detection.
		signature += ":";
		signature += shift_pressed ? "S" : "-";
		signature += ctrl_pressed ? "C" : "-";
		signature += alt_pressed ? "A" : "-";
		signature += meta_pressed ? "M" : "-";
	}
	return signature;
}

void CommonUIBinding::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_device_kind", "kind"), &CommonUIBinding::set_device_kind);
	ClassDB::bind_method(D_METHOD("get_device_kind"), &CommonUIBinding::get_device_kind);
	ClassDB::bind_method(D_METHOD("set_slot", "slot"), &CommonUIBinding::set_slot);
	ClassDB::bind_method(D_METHOD("get_slot"), &CommonUIBinding::get_slot);
	ClassDB::bind_method(D_METHOD("set_code", "code"), &CommonUIBinding::set_code);
	ClassDB::bind_method(D_METHOD("get_code"), &CommonUIBinding::get_code);
	ClassDB::bind_method(D_METHOD("set_axis_direction", "direction"), &CommonUIBinding::set_axis_direction);
	ClassDB::bind_method(D_METHOD("get_axis_direction"), &CommonUIBinding::get_axis_direction);
	ClassDB::bind_method(D_METHOD("set_dead_zone", "dead_zone"), &CommonUIBinding::set_dead_zone);
	ClassDB::bind_method(D_METHOD("get_dead_zone"), &CommonUIBinding::get_dead_zone);
	ClassDB::bind_method(D_METHOD("set_shift_pressed", "pressed"), &CommonUIBinding::set_shift_pressed);
	ClassDB::bind_method(D_METHOD("is_shift_pressed"), &CommonUIBinding::is_shift_pressed);
	ClassDB::bind_method(D_METHOD("set_ctrl_pressed", "pressed"), &CommonUIBinding::set_ctrl_pressed);
	ClassDB::bind_method(D_METHOD("is_ctrl_pressed"), &CommonUIBinding::is_ctrl_pressed);
	ClassDB::bind_method(D_METHOD("set_alt_pressed", "pressed"), &CommonUIBinding::set_alt_pressed);
	ClassDB::bind_method(D_METHOD("is_alt_pressed"), &CommonUIBinding::is_alt_pressed);
	ClassDB::bind_method(D_METHOD("set_meta_pressed", "pressed"), &CommonUIBinding::set_meta_pressed);
	ClassDB::bind_method(D_METHOD("is_meta_pressed"), &CommonUIBinding::is_meta_pressed);
	ClassDB::bind_method(D_METHOD("set_glyph_id", "glyph_id"), &CommonUIBinding::set_glyph_id);
	ClassDB::bind_method(D_METHOD("get_glyph_id"), &CommonUIBinding::get_glyph_id);
	ClassDB::bind_method(D_METHOD("to_input_event"), &CommonUIBinding::to_input_event);
	ClassDB::bind_method(D_METHOD("get_signature"), &CommonUIBinding::get_signature);
	ClassDB::bind_method(D_METHOD("is_valid_binding"), &CommonUIBinding::is_valid_binding);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "device_kind", PROPERTY_HINT_ENUM,
						 "Keyboard,Mouse,Gamepad Button,Gamepad Axis,Touch"),
			"set_device_kind", "get_device_kind");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slot", PROPERTY_HINT_ENUM, "Primary,Secondary"),
			"set_slot", "get_slot");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "code"), "set_code", "get_code");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "axis_direction", PROPERTY_HINT_ENUM,
						 "None,Positive,Negative"),
			"set_axis_direction", "get_axis_direction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "dead_zone", PROPERTY_HINT_RANGE, "0.0,1.0,0.01"),
			"set_dead_zone", "get_dead_zone");
	ADD_GROUP("Modifiers", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shift_pressed"), "set_shift_pressed", "is_shift_pressed");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ctrl_pressed"), "set_ctrl_pressed", "is_ctrl_pressed");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "alt_pressed"), "set_alt_pressed", "is_alt_pressed");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "meta_pressed"), "set_meta_pressed", "is_meta_pressed");
	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "glyph_id"), "set_glyph_id", "get_glyph_id");

	BIND_ENUM_CONSTANT(DEVICE_KEYBOARD);
	BIND_ENUM_CONSTANT(DEVICE_MOUSE);
	BIND_ENUM_CONSTANT(DEVICE_GAMEPAD_BUTTON);
	BIND_ENUM_CONSTANT(DEVICE_GAMEPAD_AXIS);
	BIND_ENUM_CONSTANT(DEVICE_TOUCH);
	BIND_ENUM_CONSTANT(AXIS_DIRECTION_NONE);
	BIND_ENUM_CONSTANT(AXIS_DIRECTION_POSITIVE);
	BIND_ENUM_CONSTANT(AXIS_DIRECTION_NEGATIVE);
	BIND_ENUM_CONSTANT(SLOT_PRIMARY);
	BIND_ENUM_CONSTANT(SLOT_SECONDARY);
}

} // namespace godot
