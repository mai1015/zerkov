#ifndef COMMON_UI_CORE_ENUMS_H
#define COMMON_UI_CORE_ENUMS_H

#include <cstdint>

namespace cu {

// Result a routed handler returns. The values are mirrored by
// CommonUIRuntime.RouteResult in ClassDB and must stay stable.
enum class RouteResult : std::uint8_t {
	// Continue routing; do not consume the Godot event on this handler's behalf.
	UNHANDLED = 0,
	// Stop routing and consume the Godot event.
	HANDLED = 1,
	// Continue framework routing but consume the Godot event once routing ends.
	HANDLED_CONTINUE = 2,
};

inline bool is_consuming(RouteResult p_result) {
	return p_result != RouteResult::UNHANDLED;
}

// Phase of a captured trigger sequence.
enum class TriggerPhase : std::uint8_t {
	PRESSED = 0,
	RELEASED = 1,
	HOLD_STARTED = 2,
	HOLD_REPEAT = 3,
	CANCELED = 4,
};

// Why a candidate handler was not invoked. Reported by routing diagnostics so
// consumers can see the decision without instrumenting handlers.
enum class Ineligible : std::uint8_t {
	NONE = 0,
	RELEASED = 1,
	OWNER_INVALID = 2,
	CONTEXT_INACTIVE = 3,
	CONTEXT_SUSPENDED = 4,
	LAYER_INACTIVE = 5,
	SCREEN_INACTIVE = 6,
	SCREEN_NOT_TOP = 7,
	// Routing stopped at a higher-priority handler that returned HANDLED.
	ROUTING_STOPPED = 8,
};

// Physical input modality currently driving the UI.
enum class Modality : std::uint8_t {
	UNKNOWN = 0,
	KEYBOARD_MOUSE = 1,
	GAMEPAD = 2,
	TOUCH = 3,
};

} // namespace cu

#endif // COMMON_UI_CORE_ENUMS_H
