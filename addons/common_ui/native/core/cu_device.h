#ifndef COMMON_UI_CORE_DEVICE_H
#define COMMON_UI_CORE_DEVICE_H

#include "core/cu_enums.h"
#include "core/cu_ids.h"

#include <unordered_map>

namespace cu {

struct ModalityPolicy {
	// Accumulated mouse motion, in pixels, needed to take modality from a
	// non-pointer device. Filters jitter from a resting mouse.
	double mouse_jitter_threshold = 8.0;
	// Axis magnitude below which a stick event is drift.
	double stick_dead_zone = 0.25;
	// Minimum dwell before another modality may take over.
	TimeUsec hysteresis_usec = 150'000;
	// A deliberate click always wins regardless of accumulated motion.
	bool mouse_button_always_activates = true;
	// Maximum gap between two mouse-motion observations before the pixels
	// accumulated so far are treated as stale and discarded. Without this, tiny
	// jitter from a resting mouse (desk vibration, sensor noise) accumulates
	// forever while another modality is active and eventually crosses
	// mouse_jitter_threshold on its own, flipping modality with no real
	// intentional motion behind it.
	TimeUsec mouse_motion_decay_usec = 500'000;
};

// Decides which physical modality is currently driving the UI.
//
// Observation never consumes input; the tracker only records what it saw. All
// timing is supplied by the caller so the behaviour is reproducible in tests.
class ModalityTracker {
public:
	void set_policy(const ModalityPolicy &p_policy) { policy = p_policy; }
	const ModalityPolicy &get_policy() const { return policy; }

	// Each observer returns true when the active modality changed.
	bool observe_mouse_motion(double p_relative_length, TimeUsec p_time_usec);
	bool observe_mouse_button(TimeUsec p_time_usec);
	bool observe_key(TimeUsec p_time_usec);
	bool observe_gamepad_button(DeviceId p_device, TimeUsec p_time_usec);
	// Returns false and ignores the event entirely while inside the dead zone.
	bool observe_gamepad_axis(DeviceId p_device, double p_magnitude, TimeUsec p_time_usec);
	bool observe_touch(TimeUsec p_time_usec);

	// True when the disconnect cleared the active modality.
	bool device_disconnected(DeviceId p_device, TimeUsec p_time_usec);

	// True when an axis magnitude is drift and must neither route nor switch
	// modality.
	bool is_within_dead_zone(double p_magnitude) const {
		return p_magnitude < policy.stick_dead_zone;
	}

	Modality get_modality() const { return modality; }
	DeviceId get_active_device() const { return active_device; }
	double get_pending_mouse_motion() const { return pending_mouse_motion; }

private:
	bool switch_to(Modality p_modality, DeviceId p_device, TimeUsec p_time_usec);

	ModalityPolicy policy;
	Modality modality = Modality::UNKNOWN;
	DeviceId active_device = INVALID_DEVICE;
	TimeUsec last_change_usec = 0;
	double pending_mouse_motion = 0.0;
	TimeUsec last_mouse_motion_usec = 0;
	bool has_pending_mouse_sample = false;
};

// Maps physical devices to UI users.
class DeviceAssignment {
public:
	void assign(DeviceId p_device, UserId p_user);
	void unassign(DeviceId p_device);
	bool is_assigned(DeviceId p_device) const;

	// Unassigned devices route to user 0 while the default-user policy is on;
	// otherwise they route nowhere. One event never reaches two users unless the
	// shared-device policy is enabled.
	UserId user_for(DeviceId p_device) const;
	bool routes_anywhere(DeviceId p_device) const;

	void set_unassigned_use_default_user(bool p_enabled) { unassigned_use_default_user = p_enabled; }
	bool is_unassigned_using_default_user() const { return unassigned_use_default_user; }

	void set_shared_device_policy(bool p_enabled) { shared_device_policy = p_enabled; }
	bool is_shared_device_policy_enabled() const { return shared_device_policy; }

	void clear() { assignments.clear(); }

private:
	std::unordered_map<DeviceId, UserId> assignments;
	bool unassigned_use_default_user = true;
	bool shared_device_policy = false;
};

} // namespace cu

#endif // COMMON_UI_CORE_DEVICE_H
