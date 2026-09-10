#ifndef COMMON_UI_INPUT_POLICY_H
#define COMMON_UI_INPUT_POLICY_H

#include <godot_cpp/classes/resource.hpp>

namespace godot {

// Thresholds that decide when observed physical input is intentional enough to
// change the active input modality.
class CommonUIInputPolicy : public Resource {
	GDCLASS(CommonUIInputPolicy, Resource)

public:
	// Accumulated mouse motion, in pixels, required to take modality away from a
	// gamepad. Filters jitter from a resting mouse.
	void set_mouse_jitter_threshold(double p_pixels);
	double get_mouse_jitter_threshold() const { return mouse_jitter_threshold; }

	// Axis magnitude below which a stick event is drift and is ignored.
	void set_stick_dead_zone(double p_dead_zone);
	double get_stick_dead_zone() const { return stick_dead_zone; }

	// Minimum time a modality must be held before another may take over.
	void set_modality_hysteresis(double p_seconds);
	double get_modality_hysteresis() const { return modality_hysteresis; }

	// Maximum gap between two mouse-motion observations before the pixels
	// accumulated so far are discarded as stale. Without this, tiny jitter from
	// a resting mouse (desk vibration, sensor noise) would accumulate forever
	// while another modality is active and eventually cross
	// mouse_jitter_threshold on its own.
	void set_mouse_motion_decay(double p_seconds);
	double get_mouse_motion_decay() const { return mouse_motion_decay; }

	// Whether a mouse button always wins regardless of accumulated motion.
	void set_mouse_button_always_activates(bool p_enabled);
	bool is_mouse_button_always_activating() const { return mouse_button_always_activates; }

	// Whether an unassigned device routes to UI user 0.
	void set_unassigned_devices_use_default_user(bool p_enabled);
	bool are_unassigned_devices_using_default_user() const {
		return unassigned_devices_use_default_user;
	}

	// Whether one device event may be dispatched to more than one UI user.
	void set_shared_device_policy(bool p_enabled);
	bool is_shared_device_policy_enabled() const { return shared_device_policy; }

protected:
	static void _bind_methods();

private:
	double mouse_jitter_threshold = 8.0;
	double stick_dead_zone = 0.25;
	double modality_hysteresis = 0.15;
	double mouse_motion_decay = 0.5;
	bool mouse_button_always_activates = true;
	bool unassigned_devices_use_default_user = true;
	bool shared_device_policy = false;
};

} // namespace godot

#endif // COMMON_UI_INPUT_POLICY_H
