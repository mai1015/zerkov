#ifndef COMMON_UI_CORE_HANDLER_INVOKER_H
#define COMMON_UI_CORE_HANDLER_INVOKER_H

#include "core/cu_types.h"

namespace cu {

// The core never stores an engine pointer and never calls into Godot. It asks
// this interface whether an owner is still alive and asks it to run a handler.
// The Godot layer implements it with checked ObjectIDs and Callables; tests
// implement it with plain records.
class HandlerInvoker {
public:
	virtual ~HandlerInvoker() = default;

	// Must return false once the object behind p_owner has been freed. The core
	// relies on this instead of dereferencing anything itself.
	virtual bool is_owner_valid(OwnerId p_owner) const = 0;

	// Runs a handler. The return value is only meaningful for
	// TriggerPhase::PRESSED; other phases ignore it.
	virtual RouteResult invoke(const HandlerCall &p_call) = 0;

	// Called when a captured trigger sequence ends without a normal release,
	// including the case where no chain member could still be notified.
	virtual void on_trigger_canceled(const TriggerState &p_trigger, TimeUsec p_time_usec) {
		(void)p_trigger;
		(void)p_time_usec;
	}

	// Called after any mutation that can change the active-action snapshot of a
	// scope. The core coalesces these so at most one fires per dispatch.
	virtual void on_active_actions_changed(const ScopeKey &p_scope) { (void)p_scope; }

	// Called after a context is pushed, removed, suspended, or resumed. Like
	// active-action notifications, deferred mutations emit only after the
	// in-flight dispatch has finished.
	virtual void on_context_changed(const ScopeKey &p_scope) { (void)p_scope; }
};

} // namespace cu

#endif // COMMON_UI_CORE_HANDLER_INVOKER_H
