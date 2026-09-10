#ifndef COMMON_UI_CORE_CORE_H
#define COMMON_UI_CORE_CORE_H

#include "core/cu_handler_invoker.h"
#include "core/cu_router.h"
#include "core/cu_scope.h"
#include "core/cu_string_interner.h"
#include "core/cu_types.h"

#include <unordered_map>
#include <vector>

namespace cu {

// A state change requested while a dispatch was in flight. Queued so the
// dispatch keeps reading the snapshot it started with.
enum class DeferredKind : std::uint8_t {
	ADD_REGISTRATION,
	RELEASE_REGISTRATION,
	RELEASE_HANDLE,
	PUSH_CONTEXT,
	REMOVE_CONTEXT,
	SET_CONTEXT_SUSPENDED,
	CONFIGURE_LAYER,
	SET_LAYER_ACTIVE,
	PUSH_SCREEN,
	REMOVE_SCREEN,
	// Input entry points re-entered while a dispatch is already in flight (for
	// example a handler that calls press()/cancel_action() on another action
	// from inside its own PRESSED callback). Deferred the same way structural
	// mutations are, so the in-flight dispatch keeps its snapshot and the
	// re-entrant call is applied once that dispatch has fully unwound.
	PRESS_ACTION,
	RELEASE_ACTION,
	CANCEL_ACTION,
	CANCEL_DEVICE,
	// Physical-state resync (focus loss, and anything else that wants every
	// captured trigger gone regardless of device). Re-enters cancel_all_now()
	// the same way CANCEL_DEVICE re-enters cancel_device_now().
	CANCEL_ALL,
	// A Viewport stopped routing (its CommonUIViewportRouter left the tree).
	// Re-enters erase_scopes_for_viewport_now() the same way CANCEL_DEVICE
	// re-enters cancel_device_now(). Only DeferredCommand::scope.viewport is
	// read; .user is ignored since every UI user's scope for that viewport is
	// erased.
	ERASE_VIEWPORT_SCOPES,
};

struct DeferredCommand {
	DeferredKind kind = DeferredKind::ADD_REGISTRATION;
	ScopeKey scope;
	ActionRegistration registration;
	ContextEntry context;
	HandleId handle = INVALID_HANDLE;
	Id id = INVALID_ID;
	OwnerId owner = INVALID_OWNER;
	int priority = 0;
	bool flag = false;
	// Used by PRESS_ACTION / RELEASE_ACTION / CANCEL_DEVICE. `id` above doubles
	// as the action id for PRESS_ACTION / RELEASE_ACTION / CANCEL_ACTION.
	DeviceId device = INVALID_DEVICE;
	TimeUsec time_usec = 0;
	TriggerPolicy policy;
};

// Authoritative, engine-free CommonUI runtime state.
//
// Core owns every scope, hands out handles, enforces the deferred-mutation rule
// during dispatch, and drives the captured trigger lifecycle. It reads the
// clock through explicit p_time_usec arguments so behaviour is reproducible.
class Core {
public:
	explicit Core(HandlerInvoker *p_invoker) :
			invoker(p_invoker) {}

	StringInterner &names() { return interner; }
	const StringInterner &names() const { return interner; }

	// -- Registration -------------------------------------------------------

	// Returns INVALID_HANDLE when the request is missing an action or owner.
	// The handle is valid immediately even when the insertion is deferred.
	HandleId register_action(const RegistrationRequest &p_request);
	bool release_registration(HandleId p_handle);

	// Releases a handle without the caller knowing whether it names a
	// registration or a context. Callers that hand out both kinds must use this:
	// guessing wrong previously dropped the handle's scope mapping and left the
	// real entry stranded.
	bool release_handle(HandleId p_handle);

	// -- Contexts -----------------------------------------------------------

	HandleId push_context(const ScopeKey &p_scope, Id p_context, int p_priority);
	bool remove_context(HandleId p_handle);
	bool set_context_suspended(HandleId p_handle, bool p_suspended);

	// -- Layers and screens -------------------------------------------------

	void configure_layer(const ScopeKey &p_scope, Id p_layer, int p_priority, bool p_active);
	void set_layer_active(const ScopeKey &p_scope, Id p_layer, bool p_active);
	// False when p_layer was never configured in this scope, in which case
	// nothing was pushed. The caller decides how loudly to report that.
	bool push_screen(const ScopeKey &p_scope, Id p_layer, OwnerId p_screen);
	void remove_screen(const ScopeKey &p_scope, Id p_layer, OwnerId p_screen);
	OwnerId top_screen(const ScopeKey &p_scope, Id p_layer) const;

	// -- Viewport teardown ----------------------------------------------------

	// Erases every scope belonging to p_viewport, across every UI user:
	// cancels any trigger captured there (delivering CANCELED to still-live
	// chain members) and drops the registrations' and contexts' handle
	// bookkeeping. For CommonUIViewportRouter teardown -- a SubViewport that
	// stops routing must not leave its scope state, and the handles pointing
	// at it, stranded in Core forever. Deferred like every other structural
	// mutator when called while a dispatch is in flight.
	void erase_scopes_for_viewport(ViewportId p_viewport, TimeUsec p_time_usec);

	// -- Input --------------------------------------------------------------

	// Routes a press and captures the consuming chain. A press for an action
	// that already has a live trigger is ignored so operating-system key echo
	// cannot restart the sequence.
	RouteReport press(const ScopeKey &p_scope, Id p_action, DeviceId p_device,
			TimeUsec p_time_usec, const TriggerPolicy &p_policy);

	// Delivers RELEASED to the still-valid members of the captured chain.
	bool release(const ScopeKey &p_scope, Id p_action, DeviceId p_device, TimeUsec p_time_usec);

	// Advances hold and repeat timing for every live trigger.
	void tick(TimeUsec p_time_usec);

	// Cancels every trigger captured from p_device.
	void cancel_device(DeviceId p_device, TimeUsec p_time_usec);

	// Cancels one trigger explicitly.
	bool cancel_action(const ScopeKey &p_scope, Id p_action, TimeUsec p_time_usec);

	// Cancels every captured trigger in every scope, regardless of device. For
	// physical-state resync: the engine layer calls this on application/window
	// focus loss, when nothing guarantees a held action's release will ever
	// arrive (see CommonUIRuntime::_notification).
	void cancel_all(TimeUsec p_time_usec);

	// -- Snapshots ----------------------------------------------------------

	std::vector<ActiveAction> active_actions(const ScopeKey &p_scope) const;

	// Active contexts of a scope, ordered exactly as routing evaluates them.
	// Suspended entries are included and flagged, because a consumer needs to
	// see that a context is present but ineligible.
	std::vector<ContextEntry> active_contexts(const ScopeKey &p_scope) const;

	// Trigger sequences currently captured in a scope.
	std::vector<TriggerState> captured_triggers(const ScopeKey &p_scope) const;
	const RouteReport &last_route() const { return last_report; }
	bool has_active_trigger(const ScopeKey &p_scope, Id p_action) const;

	// True while the core still owns p_handle, i.e. it has neither been released
	// nor removed with its owner.
	bool is_handle_known(HandleId p_handle) const {
		return handle_scopes.find(p_handle) != handle_scopes.end();
	}
	// Owner recorded for a still-known handle (registration or context), or
	// INVALID_OWNER when the handle is gone or not owner-bound. Lets the engine
	// layer answer is_active() accurately between amortized prune passes.
	OwnerId owner_of_handle(HandleId p_handle) const;
	const TriggerState *find_trigger(const ScopeKey &p_scope, Id p_action) const;
	std::vector<ScopeKey> known_scopes() const;
	// Cheap global check so a per-frame caller (physical-state reconciliation)
	// can skip the rest of its work when nothing is captured anywhere.
	bool has_captured_triggers() const { return !triggers.empty(); }

	// Sorted, unique action ids that currently have at least one registration in
	// any scope. The engine layer uses this to decide which InputMap actions an
	// incoming event needs to be tested against.
	std::vector<Id> registered_actions() const;
	bool is_dispatching() const { return dispatch_depth > 0; }

	// Drops registrations whose owner has been freed. Called automatically
	// before each dispatch; exposed for tests and periodic maintenance.
	int prune_dead_owners();

private:
	ScopeState &ensure_scope(const ScopeKey &p_scope);
	const ScopeState *find_scope(const ScopeKey &p_scope) const;
	ScopeState *find_scope_mutable(const ScopeKey &p_scope);

	void enqueue(const DeferredCommand &p_command);
	// No-op while a dispatch is in flight (dispatch_depth > 0); carries its own
	// guard so every call site is safe by construction instead of relying on
	// each caller to remember to check first.
	void flush_deferred();
	// Takes the command by value: applying a PRESS_ACTION/RELEASE_ACTION/
	// CANCEL_ACTION/CANCEL_DEVICE command can run a nested dispatch, and a
	// handler invoked from it may enqueue further commands. That can grow and
	// reallocate `deferred` while flush_deferred()'s loop is still iterating
	// it, so a reference into the vector would risk dangling; a value copy
	// cannot.
	void apply(DeferredCommand p_command);

	void mark_dirty(const ScopeKey &p_scope);
	void mark_context_dirty(const ScopeKey &p_scope);
	void flush_notifications();

	// Delivers p_phase to the surviving members of p_trigger, cancelling the
	// members that are no longer eligible. Returns false when the whole trigger
	// was cancelled.
	// Takes the trigger by value: delivery can erase or rewrite the entry this
	// was read from, so it must not alias the live vector.
	bool deliver_phase(TriggerState p_trigger, TriggerPhase p_phase, TimeUsec p_time_usec,
			int p_repeat_index);

	// Cancels triggers invalidated by a state change since the last dispatch.
	void revalidate_triggers(TimeUsec p_time_usec);

	void cancel_trigger_at(std::size_t p_index, TimeUsec p_time_usec);
	std::size_t find_trigger_index(const ScopeKey &p_scope, Id p_action) const;
	// Index of the trigger release() would act on, or triggers.size() when none
	// matches (no captured trigger, or it was captured by a different device).
	std::size_t find_releasable_trigger_index(const ScopeKey &p_scope, Id p_action,
			DeviceId p_device) const;

	// Non-deferring cores of four of the five input entry points (tick() has no
	// "_now" twin: it bails out defensively instead of deferring -- see its
	// definition). Each assumes dispatch_depth is already 0 on entry (the
	// public wrapper either checked that directly or is being called from
	// apply(), which only runs at depth 0) and does not itself call
	// flush_deferred()/flush_notifications() -- the wrapper that invoked it
	// does that once, after every deferred command from the same flush has
	// been applied.
	RouteReport press_now(const ScopeKey &p_scope, Id p_action, DeviceId p_device,
			TimeUsec p_time_usec, const TriggerPolicy &p_policy);
	bool release_now(const ScopeKey &p_scope, Id p_action, DeviceId p_device, TimeUsec p_time_usec);
	bool cancel_action_now(const ScopeKey &p_scope, Id p_action, TimeUsec p_time_usec);
	void cancel_device_now(DeviceId p_device, TimeUsec p_time_usec);
	void cancel_all_now(TimeUsec p_time_usec);
	void erase_scopes_for_viewport_now(ViewportId p_viewport, TimeUsec p_time_usec);

	HandlerInvoker *invoker = nullptr;
	StringInterner interner;

	std::unordered_map<ScopeKey, ScopeState, ScopeKeyHash> scopes;
	// Handle -> owning scope, so handle-only operations can find their state.
	std::unordered_map<HandleId, ScopeKey> handle_scopes;

	std::vector<TriggerState> triggers;
	std::vector<DeferredCommand> deferred;
	std::vector<ScopeKey> dirty_scopes;
	std::vector<ScopeKey> dirty_context_scopes;

	RouteReport last_report;

	HandleId next_handle = 1;
	std::uint64_t next_sequence = 1;
	// Monotonic identity for captured triggers; see TriggerState::serial.
	std::uint64_t next_trigger_serial = 1;
	int dispatch_depth = 0;
	bool notifying = false;
	TimeUsec last_time_usec = 0;
};

} // namespace cu

#endif // COMMON_UI_CORE_CORE_H
