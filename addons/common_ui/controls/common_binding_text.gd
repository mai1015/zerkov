@tool
class_name CommonBindingText
extends RefCounted

## Formats a [CommonUIBinding] as a short, human-readable label -- "Esc",
## "Enter", "A", "LB", "Axis 1-".
##
## Presentation-only. [InputGlyph] uses it as the fallback when a project ships
## no glyph texture for the resolved identifier, so an action bar reads
## "Enter  Confirm" instead of "key_enter  Confirm". Rebinding UIs use it to
## label the current binding of each row.

## Concise, Xbox-style names for the common pad buttons.
const _PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-Up", JOY_BUTTON_DPAD_DOWN: "D-Down",
	JOY_BUTTON_DPAD_LEFT: "D-Left", JOY_BUTTON_DPAD_RIGHT: "D-Right",
}


## Short label for a binding, or "" when it is null or invalid.
static func describe(binding: CommonUIBinding) -> String:
	if binding == null or not binding.is_valid_binding():
		return ""
	match binding.get_device_kind():
		CommonUIBinding.DEVICE_KEYBOARD:
			return _with_modifiers(binding, OS.get_keycode_string(binding.get_code()))
		CommonUIBinding.DEVICE_MOUSE:
			return "Mouse %d" % binding.get_code()
		CommonUIBinding.DEVICE_GAMEPAD_BUTTON:
			return _PAD_BUTTON_NAMES.get(binding.get_code(), "Button %d" % binding.get_code())
		CommonUIBinding.DEVICE_GAMEPAD_AXIS:
			var direction := "+" if binding.get_axis_direction() == CommonUIBinding.AXIS_DIRECTION_POSITIVE else "-"
			return "Axis %d%s" % [binding.get_code(), direction]
	return ""


static func _with_modifiers(binding: CommonUIBinding, base: String) -> String:
	var prefix := ""
	if binding.is_ctrl_pressed():
		prefix += "Ctrl+"
	if binding.is_shift_pressed():
		prefix += "Shift+"
	if binding.is_alt_pressed():
		prefix += "Alt+"
	if binding.is_meta_pressed():
		prefix += "Meta+"
	return prefix + base
