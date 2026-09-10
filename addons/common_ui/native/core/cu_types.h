#ifndef COMMON_UI_CORE_TYPES_H
#define COMMON_UI_CORE_TYPES_H

#include "core/cu_enums.h"
#include "core/cu_ids.h"

#include <vector>

namespace cu {

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// What a consumer asks for when registering an action handler.
struct RegistrationRequest {
	ScopeKey scope;
	Id action = INVALID_ID;
	// INVALID_ID means the handler is eligible whenever no more specific
	// context-scoped handler claims the action first.
	Id context = INVALID_ID;
	// INVALID_ID means the handler is not bound to a UI layer.
	Id layer = INVALID_ID;
	// INVALID_OWNER means the handler is not bound to a screen. A screen-scoped
	// handler is only eligible while its screen is the routing-active top of its
	// layer.
	OwnerId screen = INVALID_OWNER;
	// Object whose lifetime governs the registration. Required.
	OwnerId owner = INVALID_OWNER;
	int priority = 0;
	// Trigger timing for presses claimed through this registration.
	TimeUsec hold_threshold_usec = 0;
	TimeUsec repeat_interval_usec = 0;
	bool repeat_enabled = false;
	// True when the caller explicitly supplied hold/repeat timing above, as
	// opposed to leaving every field at its zero/false default. A registration
	// cannot express "explicitly wants a zero hold threshold" without this
	// marker, since 0 is indistinguishable from "unset" -- and a caller-supplied
	// policy (typically resolved from a loaded CommonUIInputConfig action, whose
	// own default hold_threshold is a non-zero 0.4s) is not itself zero either,
	// so a zero-only fallback can never fire once a config is loaded. See
	// Core::press_now()'s trigger-policy merge, which this marker drives.
	bool has_trigger_policy = false;
	// Display metadata forwarded to action bars via active-action snapshots.
	int display_priority = 0;
	bool show_in_action_bar = true;
};

struct ActionRegistration {
	HandleId handle = INVALID_HANDLE;
	Id action = INVALID_ID;
	Id context = INVALID_ID;
	Id layer = INVALID_ID;
	OwnerId screen = INVALID_OWNER;
	OwnerId owner = INVALID_OWNER;
	int priority = 0;
	// Monotonic registration counter. Higher means more recent; used as the
	// documented tie-breaker for otherwise equal candidates.
	std::uint64_t sequence = 0;
	bool released = false;
	TimeUsec hold_threshold_usec = 0;
	TimeUsec repeat_interval_usec = 0;
	bool repeat_enabled = false;
	// Mirrors RegistrationRequest::has_trigger_policy; see its comment.
	bool has_trigger_policy = false;
	int display_priority = 0;
	bool show_in_action_bar = true;
};

// ---------------------------------------------------------------------------
// Contexts and layers
// ---------------------------------------------------------------------------

struct ContextEntry {
	HandleId handle = INVALID_HANDLE;
	Id context = INVALID_ID;
	int priority = 0;
	std::uint64_t sequence = 0;
	bool suspended = false;
};

struct LayerEntry {
	Id layer = INVALID_ID;
	int priority = 0;
	bool active = true;
	std::uint64_t sequence = 0;
	// Ordered screen stack; back() is the routing-active top screen.
	std::vector<OwnerId> stack;
};

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

// One considered registration and why it was or was not invoked.
struct RouteEntry {
	HandleId registration = INVALID_HANDLE;
	Ineligible reason = Ineligible::NONE;
	// Position in the evaluation order, or -1 when the candidate was ineligible
	// before ordering.
	int order = -1;
	bool invoked = false;
	RouteResult result = RouteResult::UNHANDLED;
};

// Immutable record of a single routing decision.
struct RouteReport {
	Id action = INVALID_ID;
	ScopeKey scope;
	DeviceId device = INVALID_DEVICE;
	// True when any evaluated handler returned a consuming result, meaning the
	// originating Godot event must be marked handled.
	bool consumed = false;
	// True when a handler returned HANDLED and stopped routing early.
	bool stopped = false;
	// True when this press was not routed at all because the action already had
	// a live captured trigger -- true OS key echo from the same device, or a
	// second device pressing an action another device already holds. `consumed`
	// still reflects whether the originating Godot event must be marked
	// handled (true for the second-device case, false for same-device echo);
	// this flag exists so a caller/diagnostic can tell "suppressed" apart from
	// "genuinely not routed" without re-deriving it from an empty chain.
	bool suppressed = false;
	// Handlers that returned a consuming result, in invocation order. This is
	// the chain captured by a press for later trigger phases.
	std::vector<HandleId> chain;
	std::vector<RouteEntry> entries;
};

// ---------------------------------------------------------------------------
// Trigger lifecycle
// ---------------------------------------------------------------------------

struct TriggerPolicy {
	TimeUsec hold_threshold_usec = 0;
	TimeUsec repeat_interval_usec = 0;
	bool repeat_enabled = false;
};

struct TriggerState {
	ScopeKey scope;
	Id action = INVALID_ID;
	DeviceId device = INVALID_DEVICE;
	std::vector<HandleId> chain;
	TimeUsec pressed_usec = 0;
	bool hold_started = false;
	TimeUsec next_repeat_usec = 0;
	int repeat_index = 0;
	TriggerPolicy policy;
	// Monotonic identity assigned when the trigger is captured (see
	// Core::press_now()). Lets a caller holding a stale TriggerState copy
	// (Core::deliver_phase()'s p_trigger parameter, in particular) tell a
	// still-live trigger apart from a same-(scope, action) trigger that was
	// cancelled and recaptured while it was working -- (scope, action) alone
	// is not enough once that can happen mid-phase.
	std::uint64_t serial = 0;
};

// One handler invocation requested by the core.
struct HandlerCall {
	HandleId registration = INVALID_HANDLE;
	Id action = INVALID_ID;
	TriggerPhase phase = TriggerPhase::PRESSED;
	ScopeKey scope;
	DeviceId device = INVALID_DEVICE;
	TimeUsec time_usec = 0;
	// Zero-based repeat counter for HOLD_REPEAT, otherwise 0.
	int repeat_index = 0;
};

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

// One entry of an immutable active-action snapshot, ordered the same way the
// router would evaluate it.
struct ActiveAction {
	Id action = INVALID_ID;
	HandleId registration = INVALID_HANDLE;
	Id context = INVALID_ID;
	Id layer = INVALID_ID;
	OwnerId screen = INVALID_OWNER;
	int priority = 0;
	int display_priority = 0;
	bool show_in_action_bar = true;
};

} // namespace cu

#endif // COMMON_UI_CORE_TYPES_H
