#include "core/cu_device.h"

namespace cu {

bool ModalityTracker::switch_to(Modality p_modality, DeviceId p_device, TimeUsec p_time_usec) {
	if (modality == p_modality) {
		if (active_device == p_device) {
			return false;
		}
		// Same modality, different physical device: swapping between two
		// gamepads still changes which device profile and glyph set apply, so
		// this counts as a change even though the modality is unchanged.
		active_device = p_device;
		return true;
	}
	// The first observation establishes a modality immediately; later changes
	// must wait out the hysteresis window so alternating input cannot flicker.
	if (modality != Modality::UNKNOWN && p_time_usec - last_change_usec < policy.hysteresis_usec) {
		return false;
	}
	modality = p_modality;
	active_device = p_device;
	last_change_usec = p_time_usec;
	pending_mouse_motion = 0.0;
	has_pending_mouse_sample = false;
	return true;
}

bool ModalityTracker::observe_mouse_motion(double p_relative_length, TimeUsec p_time_usec) {
	if (modality == Modality::KEYBOARD_MOUSE) {
		pending_mouse_motion = 0.0;
		active_device = INVALID_DEVICE;
		has_pending_mouse_sample = false;
		return false;
	}
	// Motion observed while another modality drives the UI only counts as
	// intent when the samples arrive close together. A long gap since the last
	// one means whatever accumulated before is stale (desk vibration, sensor
	// noise from a resting mouse) and must not eventually cross the jitter
	// threshold purely because enough wall-clock time passed.
	if (has_pending_mouse_sample && p_time_usec - last_mouse_motion_usec > policy.mouse_motion_decay_usec) {
		pending_mouse_motion = 0.0;
	}
	has_pending_mouse_sample = true;
	last_mouse_motion_usec = p_time_usec;

	// Motion has to accumulate past the jitter threshold before it counts as
	// intent, so a nudged mouse cannot steal modality from a gamepad.
	pending_mouse_motion += p_relative_length < 0.0 ? 0.0 : p_relative_length;
	if (pending_mouse_motion < policy.mouse_jitter_threshold) {
		return false;
	}
	return switch_to(Modality::KEYBOARD_MOUSE, INVALID_DEVICE, p_time_usec);
}

bool ModalityTracker::observe_mouse_button(TimeUsec p_time_usec) {
	if (policy.mouse_button_always_activates) {
		pending_mouse_motion = policy.mouse_jitter_threshold;
	}
	return switch_to(Modality::KEYBOARD_MOUSE, INVALID_DEVICE, p_time_usec);
}

bool ModalityTracker::observe_key(TimeUsec p_time_usec) {
	return switch_to(Modality::KEYBOARD_MOUSE, INVALID_DEVICE, p_time_usec);
}

bool ModalityTracker::observe_gamepad_button(DeviceId p_device, TimeUsec p_time_usec) {
	return switch_to(Modality::GAMEPAD, p_device, p_time_usec);
}

bool ModalityTracker::observe_gamepad_axis(DeviceId p_device, double p_magnitude, TimeUsec p_time_usec) {
	if (is_within_dead_zone(p_magnitude)) {
		return false;
	}
	return switch_to(Modality::GAMEPAD, p_device, p_time_usec);
}

bool ModalityTracker::observe_touch(TimeUsec p_time_usec) {
	return switch_to(Modality::TOUCH, INVALID_DEVICE, p_time_usec);
}

bool ModalityTracker::device_disconnected(DeviceId p_device, TimeUsec p_time_usec) {
	if (active_device != p_device || modality != Modality::GAMEPAD) {
		return false;
	}
	modality = Modality::UNKNOWN;
	active_device = INVALID_DEVICE;
	last_change_usec = p_time_usec;
	pending_mouse_motion = 0.0;
	has_pending_mouse_sample = false;
	return true;
}

void DeviceAssignment::assign(DeviceId p_device, UserId p_user) {
	assignments[p_device] = p_user;
}

void DeviceAssignment::unassign(DeviceId p_device) {
	assignments.erase(p_device);
}

bool DeviceAssignment::is_assigned(DeviceId p_device) const {
	return assignments.find(p_device) != assignments.end();
}

UserId DeviceAssignment::user_for(DeviceId p_device) const {
	auto found = assignments.find(p_device);
	if (found != assignments.end()) {
		return found->second;
	}
	return DEFAULT_USER;
}

bool DeviceAssignment::routes_anywhere(DeviceId p_device) const {
	return is_assigned(p_device) || unassigned_use_default_user;
}

} // namespace cu
