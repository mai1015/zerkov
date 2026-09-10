#ifndef COMMON_UI_BINDING_H
#define COMMON_UI_BINDING_H

#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// One concrete physical binding for a logical CommonUI action.
//
// The resource is a configuration input only. CommonInputBindingRegistry copies
// its validated values into the effective binding set, so mutating a binding
// resource at runtime cannot alter an in-flight dispatch.
class CommonUIBinding : public Resource {
	GDCLASS(CommonUIBinding, Resource)

public:
	enum DeviceKind {
		DEVICE_KEYBOARD = 0,
		DEVICE_MOUSE = 1,
		DEVICE_GAMEPAD_BUTTON = 2,
		DEVICE_GAMEPAD_AXIS = 3,
		DEVICE_TOUCH = 4,
	};

	enum AxisDirection {
		AXIS_DIRECTION_NONE = 0,
		AXIS_DIRECTION_POSITIVE = 1,
		AXIS_DIRECTION_NEGATIVE = 2,
	};

	enum Slot {
		SLOT_PRIMARY = 0,
		SLOT_SECONDARY = 1,
	};

	void set_device_kind(DeviceKind p_kind);
	DeviceKind get_device_kind() const { return device_kind; }

	void set_slot(Slot p_slot);
	Slot get_slot() const { return slot; }

	// Physical key, mouse button index, joypad button index, or joypad axis
	// index depending on device_kind.
	void set_code(int p_code);
	int get_code() const { return code; }

	void set_axis_direction(AxisDirection p_direction);
	AxisDirection get_axis_direction() const { return axis_direction; }

	void set_dead_zone(float p_dead_zone);
	float get_dead_zone() const { return dead_zone; }

	// Exact modifier state required for a keyboard or mouse binding to match.
	void set_shift_pressed(bool p_pressed);
	bool is_shift_pressed() const { return shift_pressed; }
	void set_ctrl_pressed(bool p_pressed);
	bool is_ctrl_pressed() const { return ctrl_pressed; }
	void set_alt_pressed(bool p_pressed);
	bool is_alt_pressed() const { return alt_pressed; }
	void set_meta_pressed(bool p_pressed);
	bool is_meta_pressed() const { return meta_pressed; }

	// Logical glyph identifier used when no device profile overrides it.
	void set_glyph_id(const StringName &p_glyph_id);
	StringName get_glyph_id() const { return glyph_id; }

	// Builds the InputEvent the binding registry projects into InputMap.
	Ref<InputEvent> to_input_event() const;

	// Stable comparison key used for conflict detection. Two bindings conflict
	// when their signatures are equal.
	String get_signature() const;

	bool is_valid_binding() const;

protected:
	static void _bind_methods();

private:
	DeviceKind device_kind = DEVICE_KEYBOARD;
	Slot slot = SLOT_PRIMARY;
	int code = 0;
	AxisDirection axis_direction = AXIS_DIRECTION_NONE;
	float dead_zone = 0.5f;
	bool shift_pressed = false;
	bool ctrl_pressed = false;
	bool alt_pressed = false;
	bool meta_pressed = false;
	StringName glyph_id;
};

} // namespace godot

VARIANT_ENUM_CAST(CommonUIBinding::DeviceKind);
VARIANT_ENUM_CAST(CommonUIBinding::AxisDirection);
VARIANT_ENUM_CAST(CommonUIBinding::Slot);

#endif // COMMON_UI_BINDING_H
