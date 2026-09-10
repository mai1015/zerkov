#include "core/cu_core.h"

#include <algorithm>

namespace cu {

// ---------------------------------------------------------------------------
// Scope lookup
// ---------------------------------------------------------------------------

ScopeState &Core::ensure_scope(const ScopeKey &p_scope) {
	auto found = scopes.find(p_scope);
	if (found != scopes.end()) {
		return found->second;
	}
	ScopeState state;
	state.key = p_scope;
	return scopes.emplace(p_scope, std::move(state)).first->second;
}

const ScopeState *Core::find_scope(const ScopeKey &p_scope) const {
	auto found = scopes.find(p_scope);
	return found == scopes.end() ? nullptr : &found->second;
}

ScopeState *Core::find_scope_mutable(const ScopeKey &p_scope) {
	auto found = scopes.find(p_scope);
	return found == scopes.end() ? nullptr : &found->second;
}

std::vector<ScopeKey> Core::known_scopes() const {
	std::vector<ScopeKey> result;
	result.reserve(scopes.size());
	for (const auto &pair : scopes) {
		result.push_back(pair.first);
	}
	std::sort(result.begin(), result.end(), [](const ScopeKey &a, const ScopeKey &b) {
		if (a.user != b.user) {
			return a.user < b.user;
		}
		return a.viewport < b.viewport;
	});
	return result;
}

std::vector<Id> Core::registered_actions() const {
	std::vector<Id> result;
	for (const auto &pair : scopes) {
		for (const ActionRegistration &registration : pair.second.all_registrations()) {
			result.push_back(registration.action);
		}
	}
	std::sort(result.begin(), result.end());
	result.erase(std::unique(result.begin(), result.end()), result.end());
	return result;
}

// ---------------------------------------------------------------------------
// Deferred mutation
// ---------------------------------------------------------------------------

void Core::enqueue(const DeferredCommand &p_command) {
	deferred.push_back(p_command);
}

void Core::flush_deferred() {
	// A dispatch in flight must keep reading the snapshot it started with, so
	// this is a no-op until that dispatch has fully unwound. Guarding here
	// instead of at each call site means a call site cannot forget the check.
	if (dispatch_depth > 0) {
		return;
	}
	// Applying a command used to be unable to enqueue another one, because
	// enqueueing only happens while dispatch_depth > 0 and this runs at depth
	// 0. That is no longer true: applying a PRESS_ACTION/RELEASE_ACTION/
	// CANCEL_ACTION/CANCEL_DEVICE command runs a nested dispatch (depth 0 -> 1
	// -> 0 around it), and a handler invoked from that nested dispatch can
	// itself enqueue more commands onto `deferred`. The index loop tolerates
	// that growth: `deferred.size()` is re-read every iteration, so newly
	// appended commands are picked up in the same flush.
	for (std::size_t i = 0; i < deferred.size(); ++i) {
		apply(deferred[i]);
	}
	deferred.clear();
}

void Core::apply(DeferredCommand p_command) {
	// These re-enter a full input entry point rather than touching ScopeState
	// directly, so they must not go through the ensure_scope()/mark_dirty()
	// bookkeeping below: ensure_scope() would conjure a scope for
	// CANCEL_DEVICE (which has no scope of its own), and pressing/releasing/
	// cancelling a trigger does not itself change a scope's registration set,
	// so it must not report an active-action change.
	switch (p_command.kind) {
		case DeferredKind::PRESS_ACTION:
			press_now(p_command.scope, p_command.id, p_command.device, p_command.time_usec,
					p_command.policy);
			return;
		case DeferredKind::RELEASE_ACTION:
			release_now(p_command.scope, p_command.id, p_command.device, p_command.time_usec);
			return;
		case DeferredKind::CANCEL_ACTION:
			cancel_action_now(p_command.scope, p_command.id, p_command.time_usec);
			return;
		case DeferredKind::CANCEL_DEVICE:
			cancel_device_now(p_command.device, p_command.time_usec);
			return;
		case DeferredKind::CANCEL_ALL:
			cancel_all_now(p_command.time_usec);
			return;
		case DeferredKind::ERASE_VIEWPORT_SCOPES:
			erase_scopes_for_viewport_now(p_command.scope.viewport, p_command.time_usec);
			return;
		default:
			break;
	}

	ScopeState &state = ensure_scope(p_command.scope);
	bool context_changed = false;
	switch (p_command.kind) {
		case DeferredKind::ADD_REGISTRATION:
			state.add_registration(p_command.registration);
			break;
		case DeferredKind::RELEASE_REGISTRATION:
			if (state.release_registration(p_command.handle)) {
				handle_scopes.erase(p_command.handle);
			}
			break;
		case DeferredKind::RELEASE_HANDLE:
			if (state.release_registration(p_command.handle)) {
				handle_scopes.erase(p_command.handle);
			} else if (state.remove_context(p_command.handle)) {
				handle_scopes.erase(p_command.handle);
				context_changed = true;
			}
			break;
		case DeferredKind::PUSH_CONTEXT:
			state.push_context(p_command.context);
			context_changed = true;
			break;
		case DeferredKind::REMOVE_CONTEXT:
			if (state.remove_context(p_command.handle)) {
				handle_scopes.erase(p_command.handle);
				context_changed = true;
			}
			break;
		case DeferredKind::SET_CONTEXT_SUSPENDED:
			context_changed = state.set_context_suspended(p_command.handle, p_command.flag);
			break;
		case DeferredKind::CONFIGURE_LAYER:
			state.configure_layer(p_command.id, p_command.priority, p_command.flag, next_sequence++);
			break;
		case DeferredKind::SET_LAYER_ACTIVE:
			state.set_layer_active(p_command.id, p_command.flag);
			break;
		case DeferredKind::PUSH_SCREEN:
			state.push_screen(p_command.id, p_command.owner);
			break;
		case DeferredKind::REMOVE_SCREEN:
			state.remove_screen(p_command.id, p_command.owner);
			break;
		case DeferredKind::PRESS_ACTION:
		case DeferredKind::RELEASE_ACTION:
		case DeferredKind::CANCEL_ACTION:
		case DeferredKind::CANCEL_DEVICE:
		case DeferredKind::CANCEL_ALL:
		case DeferredKind::ERASE_VIEWPORT_SCOPES:
			// Handled by the early switch above; never reached here.
			break;
	}
	mark_dirty(p_command.scope);
	if (context_changed) {
		mark_context_dirty(p_command.scope);
	}
}

void Core::mark_dirty(const ScopeKey &p_scope) {
	for (const ScopeKey &scope : dirty_scopes) {
		if (scope == p_scope) {
			return;
		}
	}
	dirty_scopes.push_back(p_scope);
}

void Core::mark_context_dirty(const ScopeKey &p_scope) {
	for (const ScopeKey &scope : dirty_context_scopes) {
		if (scope == p_scope) {
			return;
		}
	}
	dirty_context_scopes.push_back(p_scope);
}

void Core::flush_notifications() {
	if (dispatch_depth > 0 || notifying ||
			(dirty_scopes.empty() && dirty_context_scopes.empty()) || invoker == nullptr) {
		return;
	}
	notifying = true;
	std::vector<ScopeKey> pending_actions;
	std::vector<ScopeKey> pending_contexts;
	pending_actions.swap(dirty_scopes);
	pending_contexts.swap(dirty_context_scopes);
	for (const ScopeKey &scope : pending_actions) {
		invoker->on_active_actions_changed(scope);
	}
	for (const ScopeKey &scope : pending_contexts) {
		invoker->on_context_changed(scope);
	}
	notifying = false;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

HandleId Core::register_action(const RegistrationRequest &p_request) {
	if (p_request.action == INVALID_ID || p_request.owner == INVALID_OWNER) {
		return INVALID_HANDLE;
	}

	ActionRegistration registration;
	registration.handle = next_handle++;
	registration.action = p_request.action;
	registration.context = p_request.context;
	registration.layer = p_request.layer;
	registration.screen = p_request.screen;
	registration.owner = p_request.owner;
	registration.priority = p_request.priority;
	registration.sequence = next_sequence++;
	registration.hold_threshold_usec = p_request.hold_threshold_usec;
	registration.repeat_interval_usec = p_request.repeat_interval_usec;
	registration.repeat_enabled = p_request.repeat_enabled;
	registration.has_trigger_policy = p_request.has_trigger_policy;
	registration.display_priority = p_request.display_priority;
	registration.show_in_action_bar = p_request.show_in_action_bar;

	handle_scopes[registration.handle] = p_request.scope;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::ADD_REGISTRATION;
		command.scope = p_request.scope;
		command.registration = registration;
		enqueue(command);
	} else {
		ensure_scope(p_request.scope).add_registration(registration);
		mark_dirty(p_request.scope);
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return registration.handle;
}

bool Core::release_registration(HandleId p_handle) {
	auto found = handle_scopes.find(p_handle);
	if (found == handle_scopes.end()) {
		return false;
	}
	const ScopeKey scope = found->second;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::RELEASE_REGISTRATION;
		command.scope = scope;
		command.handle = p_handle;
		enqueue(command);
		return true;
	}

	ScopeState *state = find_scope_mutable(scope);
	if (state == nullptr) {
		return false;
	}
	const bool removed = state->release_registration(p_handle);
	if (removed) {
		handle_scopes.erase(p_handle);
		mark_dirty(scope);
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return removed;
}

bool Core::release_handle(HandleId p_handle) {
	auto found = handle_scopes.find(p_handle);
	if (found == handle_scopes.end()) {
		return false;
	}
	const ScopeKey scope = found->second;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::RELEASE_HANDLE;
		command.scope = scope;
		command.handle = p_handle;
		enqueue(command);
		return true;
	}

	ScopeState *state = find_scope_mutable(scope);
	if (state == nullptr) {
		return false;
	}
	// A handle names either a registration or a context; try both before
	// concluding it is gone, while retaining which kind changed for observers.
	const bool removed_registration = state->release_registration(p_handle);
	const bool removed_context = !removed_registration && state->remove_context(p_handle);
	const bool removed = removed_registration || removed_context;
	if (removed) {
		handle_scopes.erase(p_handle);
		mark_dirty(scope);
		if (removed_context) {
			mark_context_dirty(scope);
		}
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return removed;
}

int Core::prune_dead_owners() {
	if (invoker == nullptr) {
		return 0;
	}
	int removed = 0;
	for (auto &pair : scopes) {
		const std::vector<HandleId> scope_removed = pair.second.prune_dead_owners(
				[this](OwnerId owner) { return invoker->is_owner_valid(owner); });
		if (!scope_removed.empty()) {
			for (HandleId handle : scope_removed) {
				handle_scopes.erase(handle);
			}
			removed += static_cast<int>(scope_removed.size());
			mark_dirty(pair.first);
		}
	}
	// Runtime maintenance can call this outside a route. Flush then so stale
	// callback caches and presentation snapshots are cleaned promptly as well.
	flush_notifications();
	return removed;
}

// ---------------------------------------------------------------------------
// Contexts
// ---------------------------------------------------------------------------

HandleId Core::push_context(const ScopeKey &p_scope, Id p_context, int p_priority) {
	if (p_context == INVALID_ID) {
		return INVALID_HANDLE;
	}
	ContextEntry entry;
	entry.handle = next_handle++;
	entry.context = p_context;
	entry.priority = p_priority;
	entry.sequence = next_sequence++;
	entry.suspended = false;

	handle_scopes[entry.handle] = p_scope;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::PUSH_CONTEXT;
		command.scope = p_scope;
		command.context = entry;
		enqueue(command);
	} else {
		ensure_scope(p_scope).push_context(entry);
		mark_dirty(p_scope);
		mark_context_dirty(p_scope);
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return entry.handle;
}

bool Core::remove_context(HandleId p_handle) {
	auto found = handle_scopes.find(p_handle);
	if (found == handle_scopes.end()) {
		return false;
	}
	const ScopeKey scope = found->second;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::REMOVE_CONTEXT;
		command.scope = scope;
		command.handle = p_handle;
		enqueue(command);
		return true;
	}

	ScopeState *state = find_scope_mutable(scope);
	if (state == nullptr) {
		return false;
	}
	const bool removed = state->remove_context(p_handle);
	if (removed) {
		handle_scopes.erase(p_handle);
		mark_dirty(scope);
		mark_context_dirty(scope);
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return removed;
}

bool Core::set_context_suspended(HandleId p_handle, bool p_suspended) {
	auto found = handle_scopes.find(p_handle);
	if (found == handle_scopes.end()) {
		return false;
	}
	const ScopeKey scope = found->second;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::SET_CONTEXT_SUSPENDED;
		command.scope = scope;
		command.handle = p_handle;
		command.flag = p_suspended;
		enqueue(command);
		return true;
	}

	ScopeState *state = find_scope_mutable(scope);
	if (state == nullptr) {
		return false;
	}
	const bool changed = state->set_context_suspended(p_handle, p_suspended);
	if (changed) {
		mark_dirty(scope);
		mark_context_dirty(scope);
		revalidate_triggers(last_time_usec);
		flush_notifications();
	}
	return changed;
}

// ---------------------------------------------------------------------------
// Layers and screens
// ---------------------------------------------------------------------------

void Core::configure_layer(const ScopeKey &p_scope, Id p_layer, int p_priority, bool p_active) {
	if (p_layer == INVALID_ID) {
		return;
	}
	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::CONFIGURE_LAYER;
		command.scope = p_scope;
		command.id = p_layer;
		command.priority = p_priority;
		command.flag = p_active;
		enqueue(command);
		return;
	}
	ensure_scope(p_scope).configure_layer(p_layer, p_priority, p_active, next_sequence++);
	mark_dirty(p_scope);
	revalidate_triggers(last_time_usec);
	flush_notifications();
}

void Core::set_layer_active(const ScopeKey &p_scope, Id p_layer, bool p_active) {
	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::SET_LAYER_ACTIVE;
		command.scope = p_scope;
		command.id = p_layer;
		command.flag = p_active;
		enqueue(command);
		return;
	}
	ScopeState *state = find_scope_mutable(p_scope);
	if (state == nullptr || !state->set_layer_active(p_layer, p_active)) {
		return;
	}
	mark_dirty(p_scope);
	revalidate_triggers(last_time_usec);
	flush_notifications();
}

bool Core::push_screen(const ScopeKey &p_scope, Id p_layer, OwnerId p_screen) {
	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::PUSH_SCREEN;
		command.scope = p_scope;
		command.id = p_layer;
		command.owner = p_screen;
		enqueue(command);
		// The outcome cannot be known synchronously -- the layer may still be
		// configured by another queued command before this one applies. Report
		// success so a deferred call is never treated as a spurious failure;
		// the overwhelming majority of calls run outside a dispatch and get a
		// real answer below.
		return true;
	}
	ScopeState &state = ensure_scope(p_scope);
	if (!state.push_screen(p_layer, p_screen)) {
		return false;
	}
	mark_dirty(p_scope);
	revalidate_triggers(last_time_usec);
	flush_notifications();
	return true;
}

void Core::remove_screen(const ScopeKey &p_scope, Id p_layer, OwnerId p_screen) {
	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::REMOVE_SCREEN;
		command.scope = p_scope;
		command.id = p_layer;
		command.owner = p_screen;
		enqueue(command);
		return;
	}
	ScopeState *state = find_scope_mutable(p_scope);
	if (state == nullptr || !state->remove_screen(p_layer, p_screen)) {
		return;
	}
	mark_dirty(p_scope);
	revalidate_triggers(last_time_usec);
	flush_notifications();
}

OwnerId Core::top_screen(const ScopeKey &p_scope, Id p_layer) const {
	const ScopeState *state = find_scope(p_scope);
	return state == nullptr ? INVALID_OWNER : state->top_screen(p_layer);
}

// ---------------------------------------------------------------------------
// Trigger lifecycle
// ---------------------------------------------------------------------------

std::size_t Core::find_trigger_index(const ScopeKey &p_scope, Id p_action) const {
	for (std::size_t i = 0; i < triggers.size(); ++i) {
		if (triggers[i].scope == p_scope && triggers[i].action == p_action) {
			return i;
		}
	}
	return triggers.size();
}

bool Core::has_active_trigger(const ScopeKey &p_scope, Id p_action) const {
	return find_trigger_index(p_scope, p_action) < triggers.size();
}

OwnerId Core::owner_of_handle(HandleId p_handle) const {
	const auto scope_it = handle_scopes.find(p_handle);
	if (scope_it == handle_scopes.end()) {
		return INVALID_OWNER;
	}
	const auto state_it = scopes.find(scope_it->second);
	if (state_it == scopes.end()) {
		return INVALID_OWNER;
	}
	if (const ActionRegistration *registration = state_it->second.find_registration(p_handle)) {
		return registration->owner;
	}
	// Context handles carry no owner; they are released explicitly.
	return INVALID_OWNER;
}

const TriggerState *Core::find_trigger(const ScopeKey &p_scope, Id p_action) const {
	const std::size_t at = find_trigger_index(p_scope, p_action);
	return at < triggers.size() ? &triggers[at] : nullptr;
}

std::size_t Core::find_releasable_trigger_index(const ScopeKey &p_scope, Id p_action,
		DeviceId p_device) const {
	const std::size_t at = find_trigger_index(p_scope, p_action);
	if (at >= triggers.size()) {
		return triggers.size();
	}
	// A release from a different device than the one that captured the press is
	// ignored; that device's own sequence, if any, is tracked separately.
	if (p_device != INVALID_DEVICE && triggers[at].device != INVALID_DEVICE &&
			triggers[at].device != p_device) {
		return triggers.size();
	}
	return at;
}

RouteReport Core::press_now(const ScopeKey &p_scope, Id p_action, DeviceId p_device,
		TimeUsec p_time_usec, const TriggerPolicy &p_policy) {
	RouteReport report;
	report.action = p_action;
	report.scope = p_scope;
	report.device = p_device;

	if (p_action == INVALID_ID || invoker == nullptr) {
		// No routing decision was made at all -- leave get_last_route_report()
		// (the primary debugging affordance) showing whatever the last real
		// decision was instead of blanking it with an empty, uninformative
		// record.
		return report;
	}

	// A live trigger means the platform is repeating an already-captured press,
	// or a second device is pressing an action another device already holds.
	// Either way framework hold and repeat timing owns the cadence now, so the
	// press is never routed and never rejoins/restarts the captured chain.
	const std::size_t held_at = find_trigger_index(p_scope, p_action);
	if (held_at < triggers.size()) {
		report.suppressed = true;
		// A different device must still consume the originating Godot event --
		// otherwise it falls through to gameplay's own unhandled-input stage
		// (e.g. Escape held for a menu and a gamepad's B, bound to the same
		// action, leaking a "back" press into gameplay). True repeats from the
		// SAME device -- including OS key echo -- are left exactly as before:
		// suppressed but not marked consumed, since the original press already
		// consumed the originating event on that device's behalf.
		if (triggers[held_at].device != p_device) {
			report.consumed = true;
		}
		last_report = report;
		return report;
	}

	// press() only calls press_now() at depth 0 (a re-entrant call is deferred
	// instead, see press()), and apply() only runs at depth 0 too, so this is
	// always true today. The guard is kept explicit anyway: pruning erases
	// registrations, and doing that out from under an in-flight outer dispatch
	// is exactly the hazard this whole entry point exists to avoid. The
	// per-frame _process prune covers the case this would skip.
	if (dispatch_depth == 0) {
		prune_dead_owners();
	}

	ScopeState *state = find_scope_mutable(p_scope);
	if (state == nullptr) {
		// Nothing is registered in this scope at all; same reasoning as the
		// invalid-press early-out above -- preserve the previous meaningful
		// report instead of blanking it.
		flush_notifications();
		return report;
	}

	++dispatch_depth;
	report = Router::dispatch_press(*state, *invoker, p_action, p_scope, p_device, p_time_usec);
	--dispatch_depth;

	if (!report.chain.empty()) {
		TriggerState trigger;
		trigger.scope = p_scope;
		trigger.action = p_action;
		trigger.device = p_device;
		trigger.chain = report.chain;
		trigger.pressed_usec = p_time_usec;
		trigger.hold_started = false;
		trigger.repeat_index = 0;
		trigger.policy = p_policy;
		trigger.serial = next_trigger_serial++;
		// An explicit per-registration policy on the first capturing handler
		// always wins over the policy the caller passed to press() (typically
		// resolved from the project's CommonUIInputConfig); that caller policy
		// only applies when the winning registration left its own hold/repeat
		// options unset. Gating on has_trigger_policy rather than "caller policy
		// is zero" matters because a loaded config's own default hold_threshold
		// is a non-zero 0.4s, which used to make the zero-only fallback below
		// never fire and silently ignore every registration's hold/repeat
		// options once a config was loaded.
		const ActionRegistration *first = state->find_registration(report.chain.front());
		if (first != nullptr && first->has_trigger_policy) {
			trigger.policy.hold_threshold_usec = first->hold_threshold_usec;
			trigger.policy.repeat_interval_usec = first->repeat_interval_usec;
			trigger.policy.repeat_enabled = first->repeat_enabled;
		}
		trigger.next_repeat_usec = 0;
		triggers.push_back(trigger);
	}

	last_report = report;
	return report;
}

RouteReport Core::press(const ScopeKey &p_scope, Id p_action, DeviceId p_device,
		TimeUsec p_time_usec, const TriggerPolicy &p_policy) {
	last_time_usec = p_time_usec;

	// A handler invoked by an in-flight dispatch (Router::dispatch_press,
	// deliver_phase, or cancel_trigger_at) is legal, but acting on `triggers`
	// or the routing snapshot right now would mutate state the outer dispatch
	// is still reading. Queue it and apply it once that dispatch has unwound,
	// same as every structural mutator already does.
	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::PRESS_ACTION;
		command.scope = p_scope;
		command.id = p_action;
		command.device = p_device;
		command.time_usec = p_time_usec;
		command.policy = p_policy;
		enqueue(command);

		RouteReport report;
		report.action = p_action;
		report.scope = p_scope;
		report.device = p_device;
		// No routing decision was made yet -- this press is only queued, and
		// press_now() will update last_report with the real outcome once the
		// in-flight dispatch unwinds and the deferred command applies. Preserve
		// whatever last_report already holds instead of blanking the primary
		// debugging affordance in the meantime.
		return report;
	}

	RouteReport report = press_now(p_scope, p_action, p_device, p_time_usec, p_policy);
	flush_deferred();
	revalidate_triggers(p_time_usec);
	flush_notifications();
	return report;
}

bool Core::release_now(const ScopeKey &p_scope, Id p_action, DeviceId p_device, TimeUsec p_time_usec) {
	const std::size_t trigger_at = find_trigger_index(p_scope, p_action);
	if (trigger_at >= triggers.size()) {
		// No captured trigger for this action at all: nothing to consume, and
		// nothing for gameplay to be shielded from.
		return false;
	}

	const std::size_t releasable_at = find_releasable_trigger_index(p_scope, p_action, p_device);
	if (releasable_at >= triggers.size()) {
		// A trigger exists but was captured by a different device. The press
		// that captured it already consumed the originating event on that
		// device's behalf (see press_now()'s suppressed-press handling), so its
		// release must be consumed too -- gameplay must not see an orphan
		// release for an action the menu still owns. The captured trigger
		// itself is left untouched; only its own device can actually end it.
		return true;
	}

	TriggerState trigger = triggers[releasable_at];
	triggers.erase(triggers.begin() + static_cast<std::ptrdiff_t>(releasable_at));
	deliver_phase(trigger, TriggerPhase::RELEASED, p_time_usec, 0);
	return true;
}

bool Core::release(const ScopeKey &p_scope, Id p_action, DeviceId p_device, TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;

	if (dispatch_depth > 0) {
		// Evaluated against the outer dispatch's still-unmodified snapshot, so
		// the caller gets the same answer it would have gotten had this run
		// immediately; the actual release just waits for that dispatch to
		// finish. Any captured trigger for this (scope, action) -- matched
		// device or not -- means release_now() will eventually return true (see
		// its own mismatched-device handling), so the deferred/consumed
		// decision only needs to know whether a trigger exists at all.
		if (find_trigger_index(p_scope, p_action) >= triggers.size()) {
			return false;
		}
		DeferredCommand command;
		command.kind = DeferredKind::RELEASE_ACTION;
		command.scope = p_scope;
		command.id = p_action;
		command.device = p_device;
		command.time_usec = p_time_usec;
		enqueue(command);
		return true;
	}

	if (!release_now(p_scope, p_action, p_device, p_time_usec)) {
		return false;
	}
	flush_deferred();
	revalidate_triggers(p_time_usec);
	flush_notifications();
	return true;
}

void Core::tick(TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;
	// tick() is only ever called from _process and is never expected to run
	// while a dispatch is in flight. Guard defensively anyway rather than
	// walking `triggers` mid-dispatch: unlike press/release/cancel_*, a
	// dropped tick has no queue to catch up from, so bailing out (instead of
	// deferring) is the safer failure mode if this invariant is ever broken.
	if (dispatch_depth > 0) {
		return;
	}
	if (triggers.empty()) {
		return;
	}

	// Iterate over a copy of the identifying keys so a handler that cancels or
	// adds triggers cannot invalidate the loop.
	std::vector<std::pair<ScopeKey, Id>> keys;
	keys.reserve(triggers.size());
	for (const TriggerState &trigger : triggers) {
		keys.emplace_back(trigger.scope, trigger.action);
	}

	for (const auto &key : keys) {
		std::size_t at = find_trigger_index(key.first, key.second);
		if (at >= triggers.size()) {
			continue;
		}

		const TriggerPolicy policy = triggers[at].policy;
		if (policy.hold_threshold_usec == 0) {
			continue;
		}

		if (!triggers[at].hold_started) {
			if (p_time_usec - triggers[at].pressed_usec < policy.hold_threshold_usec) {
				continue;
			}
			TriggerState working = triggers[at];
			working.hold_started = true;
			working.next_repeat_usec = working.pressed_usec + policy.hold_threshold_usec +
					policy.repeat_interval_usec;
			triggers[at] = working;
			// Exactly one hold-start notification per captured sequence.
			if (!deliver_phase(triggers[at], TriggerPhase::HOLD_STARTED, p_time_usec, 0)) {
				continue;
			}
			at = find_trigger_index(key.first, key.second);
			if (at >= triggers.size()) {
				continue;
			}
		}

		if (!policy.repeat_enabled || policy.repeat_interval_usec == 0) {
			continue;
		}

		// Framework cadence, independent of operating-system key echo. Catch up
		// deterministically if several intervals elapsed since the last tick, but
		// cap how many HOLD_REPEAT callbacks a single tick() call will fire for
		// one trigger: a hitch or a debugger pause can leave an unbounded number
		// of intervals owed, and firing all of them in one frame would stall
		// gameplay far worse than a few dropped repeats ever would.
		constexpr int MAX_REPEATS_PER_TICK = 4;
		int repeats_delivered = 0;
		while (at < triggers.size() && p_time_usec >= triggers[at].next_repeat_usec) {
			if (repeats_delivered >= MAX_REPEATS_PER_TICK) {
				// Stop catching up and resync the schedule to now instead of
				// leaving next_repeat_usec deep in the past, which would just
				// reproduce the same unbounded burst on the very next tick().
				triggers[at].next_repeat_usec = p_time_usec + policy.repeat_interval_usec;
				break;
			}
			const int repeat_index = triggers[at].repeat_index;
			triggers[at].repeat_index = repeat_index + 1;
			triggers[at].next_repeat_usec += policy.repeat_interval_usec;
			++repeats_delivered;
			if (!deliver_phase(triggers[at], TriggerPhase::HOLD_REPEAT, p_time_usec, repeat_index)) {
				break;
			}
			at = find_trigger_index(key.first, key.second);
		}
	}

	flush_deferred();
	revalidate_triggers(p_time_usec);
	flush_notifications();
}

void Core::cancel_device_now(DeviceId p_device, TimeUsec p_time_usec) {
	// Snapshot which (scope, action) pairs belong to this device before
	// cancelling any of them. cancel_trigger_at() calls
	// invoker->on_trigger_canceled() after it has already erased the trigger
	// it was handling, and that callback is arbitrary handler code: it can
	// call cancel_action()/cancel_device() itself and erase more entries from
	// `triggers`. A raw index computed once before the loop (or captured by
	// the loop bound) would then read or erase out of bounds. Re-finding each
	// trigger by identity right before acting on it -- the same pattern
	// tick() uses -- means a vanished entry is simply skipped instead.
	std::vector<std::pair<ScopeKey, Id>> keys;
	keys.reserve(triggers.size());
	for (const TriggerState &trigger : triggers) {
		if (trigger.device == p_device) {
			keys.emplace_back(trigger.scope, trigger.action);
		}
	}

	for (std::size_t i = keys.size(); i > 0; --i) {
		const auto &key = keys[i - 1];
		const std::size_t at = find_trigger_index(key.first, key.second);
		if (at >= triggers.size()) {
			// Already cancelled by an on_trigger_canceled callback triggered
			// earlier in this same loop.
			continue;
		}
		if (triggers[at].device != p_device) {
			// The (scope, action) pair was released and recaptured by a
			// different device by a callback triggered earlier in this loop.
			continue;
		}
		cancel_trigger_at(at, p_time_usec);
	}
}

void Core::cancel_device(DeviceId p_device, TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::CANCEL_DEVICE;
		command.device = p_device;
		command.time_usec = p_time_usec;
		enqueue(command);
		return;
	}

	cancel_device_now(p_device, p_time_usec);
	flush_deferred();
	flush_notifications();
}

void Core::cancel_all_now(TimeUsec p_time_usec) {
	// Snapshot every captured (scope, action) identity before cancelling any of
	// them, for the same reason cancel_device_now() and revalidate_triggers()
	// do: cancel_trigger_at() invokes invoker->on_trigger_canceled() after
	// already erasing its own entry, and that callback is arbitrary handler
	// code that can itself cancel more triggers and erase further entries from
	// `triggers`. Re-finding each trigger by identity right before acting on it
	// means a vanished entry is simply skipped instead of read or erased out of
	// bounds.
	std::vector<std::pair<ScopeKey, Id>> keys;
	keys.reserve(triggers.size());
	for (const TriggerState &trigger : triggers) {
		keys.emplace_back(trigger.scope, trigger.action);
	}

	for (std::size_t i = keys.size(); i > 0; --i) {
		const auto &key = keys[i - 1];
		const std::size_t at = find_trigger_index(key.first, key.second);
		if (at >= triggers.size()) {
			// Already cancelled by an on_trigger_canceled callback triggered
			// earlier in this same loop.
			continue;
		}
		cancel_trigger_at(at, p_time_usec);
	}
}

void Core::cancel_all(TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::CANCEL_ALL;
		command.time_usec = p_time_usec;
		enqueue(command);
		return;
	}

	cancel_all_now(p_time_usec);
	flush_deferred();
	flush_notifications();
}

// ---------------------------------------------------------------------------
// Viewport teardown
// ---------------------------------------------------------------------------

void Core::erase_scopes_for_viewport_now(ViewportId p_viewport, TimeUsec p_time_usec) {
	// Cancel every trigger captured in a scope that belongs to this viewport
	// before tearing the scope down, so still-eligible chain members get their
	// CANCELED delivery instead of silently vanishing out from under them. Same
	// snapshot-by-identity pattern as cancel_all_now(): cancel_trigger_at()
	// invokes invoker->on_trigger_canceled() after already erasing its own
	// entry, and that callback is arbitrary handler code that can itself erase
	// further entries from `triggers`.
	std::vector<std::pair<ScopeKey, Id>> keys;
	keys.reserve(triggers.size());
	for (const TriggerState &trigger : triggers) {
		if (trigger.scope.viewport == p_viewport) {
			keys.emplace_back(trigger.scope, trigger.action);
		}
	}
	for (std::size_t i = keys.size(); i > 0; --i) {
		const auto &key = keys[i - 1];
		const std::size_t at = find_trigger_index(key.first, key.second);
		if (at >= triggers.size()) {
			continue;
		}
		cancel_trigger_at(at, p_time_usec);
	}

	// Every UI user gets its own scope for the same viewport, so more than one
	// entry in `scopes` can belong to it.
	std::vector<ScopeKey> doomed;
	for (const auto &pair : scopes) {
		if (pair.first.viewport == p_viewport) {
			doomed.push_back(pair.first);
		}
	}
	for (const ScopeKey &scope_key : doomed) {
		auto found = scopes.find(scope_key);
		if (found == scopes.end()) {
			continue;
		}
		for (const ActionRegistration &registration : found->second.all_registrations()) {
			handle_scopes.erase(registration.handle);
		}
		for (const ContextEntry &entry : found->second.all_contexts()) {
			handle_scopes.erase(entry.handle);
		}
		scopes.erase(found);
		// The scope itself is gone, not merely mutated, so a consumer's cached
		// active-action/context snapshot for it is stale either way -- report
		// both changes the same way every other structural mutator does.
		mark_dirty(scope_key);
		mark_context_dirty(scope_key);
	}
}

void Core::erase_scopes_for_viewport(ViewportId p_viewport, TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;

	if (dispatch_depth > 0) {
		DeferredCommand command;
		command.kind = DeferredKind::ERASE_VIEWPORT_SCOPES;
		command.scope.viewport = p_viewport;
		command.time_usec = p_time_usec;
		enqueue(command);
		return;
	}

	erase_scopes_for_viewport_now(p_viewport, p_time_usec);
	flush_deferred();
	flush_notifications();
}

bool Core::cancel_action_now(const ScopeKey &p_scope, Id p_action, TimeUsec p_time_usec) {
	const std::size_t at = find_trigger_index(p_scope, p_action);
	if (at >= triggers.size()) {
		return false;
	}
	cancel_trigger_at(at, p_time_usec);
	return true;
}

bool Core::cancel_action(const ScopeKey &p_scope, Id p_action, TimeUsec p_time_usec) {
	last_time_usec = p_time_usec;

	if (dispatch_depth > 0) {
		if (find_trigger_index(p_scope, p_action) >= triggers.size()) {
			return false;
		}
		DeferredCommand command;
		command.kind = DeferredKind::CANCEL_ACTION;
		command.scope = p_scope;
		command.id = p_action;
		command.time_usec = p_time_usec;
		enqueue(command);
		return true;
	}

	if (!cancel_action_now(p_scope, p_action, p_time_usec)) {
		return false;
	}
	flush_deferred();
	flush_notifications();
	return true;
}

void Core::cancel_trigger_at(std::size_t p_index, TimeUsec p_time_usec) {
	TriggerState trigger = triggers[p_index];
	triggers.erase(triggers.begin() + static_cast<std::ptrdiff_t>(p_index));

	const ScopeState *state = find_scope(trigger.scope);
	if (state != nullptr && invoker != nullptr) {
		++dispatch_depth;
		for (HandleId handle : trigger.chain) {
			const ActionRegistration *registration = state->find_registration(handle);
			// A member whose object is gone cannot be notified; it is simply
			// dropped rather than retargeted.
			if (registration == nullptr || !invoker->is_owner_valid(registration->owner)) {
				continue;
			}
			HandlerCall call;
			call.registration = handle;
			call.action = trigger.action;
			call.phase = TriggerPhase::CANCELED;
			call.scope = trigger.scope;
			call.device = trigger.device;
			call.time_usec = p_time_usec;
			invoker->invoke(call);
		}
		--dispatch_depth;
	}
	if (invoker != nullptr) {
		invoker->on_trigger_canceled(trigger, p_time_usec);
	}
}

bool Core::deliver_phase(TriggerState p_trigger, TriggerPhase p_phase, TimeUsec p_time_usec,
		int p_repeat_index) {
	if (invoker == nullptr) {
		return false;
	}
	const ScopeState *state = find_scope(p_trigger.scope);
	if (state == nullptr) {
		invoker->on_trigger_canceled(p_trigger, p_time_usec);
		return false;
	}

	const ScopeRanks ranks = state->build_ranks();
	std::vector<HandleId> surviving;
	std::vector<HandleId> canceled;

	++dispatch_depth;
	// Members are visited in their captured order; the phase is never handed to
	// a handler that was not part of the original chain.
	for (HandleId handle : p_trigger.chain) {
		const ActionRegistration *registration = state->find_registration(handle);
		const bool callable = registration != nullptr && invoker->is_owner_valid(registration->owner);
		const bool eligible = callable &&
				Router::eligibility_of(*state, ranks, handle, *invoker) == Ineligible::NONE;

		if (eligible) {
			HandlerCall call;
			call.registration = handle;
			call.action = p_trigger.action;
			call.phase = p_phase;
			call.scope = p_trigger.scope;
			call.device = p_trigger.device;
			call.time_usec = p_time_usec;
			call.repeat_index = p_repeat_index;
			invoker->invoke(call);
			surviving.push_back(handle);
			continue;
		}

		canceled.push_back(handle);
		if (callable) {
			HandlerCall call;
			call.registration = handle;
			call.action = p_trigger.action;
			call.phase = TriggerPhase::CANCELED;
			call.scope = p_trigger.scope;
			call.device = p_trigger.device;
			call.time_usec = p_time_usec;
			invoker->invoke(call);
		}
	}
	--dispatch_depth;

	// A terminal phase consumed the sequence; nothing survives it. Reaching a
	// normal terminal phase (RELEASED) is not a cancellation even when some
	// chain members dropped along the way -- see on_trigger_canceled()'s
	// contract in cu_handler_invoker.h. Consumers must be able to tell
	// "the sequence was aborted mid-flight" apart from "one member was not
	// eligible for an otherwise ordinary release", and firing trigger_canceled
	// here would conflate the two. (deliver_phase() is never called with
	// TriggerPhase::CANCELED -- that phase is delivered directly by
	// cancel_trigger_at(), which always fully terminates its trigger -- but the
	// check is kept here too so this function's own contract does not depend on
	// that fact.)
	if (p_phase == TriggerPhase::RELEASED || p_phase == TriggerPhase::CANCELED) {
		return !surviving.empty();
	}

	if (surviving.empty()) {
		// Every remaining member became ineligible before the trigger could
		// terminate normally: the whole sequence is aborted mid-flight. This is
		// the only deliver_phase() branch that fires trigger_canceled; a partial
		// drop that still leaves the trigger alive (the write-back below) is not
		// a cancellation and must not be reported as one.
		//
		// Erase before notifying, exactly like cancel_trigger_at() already does:
		// on_trigger_canceled() is arbitrary listener code that can react by
		// pressing this very (scope, action) again, and that press's own
		// revalidate_triggers() pass walks the full `triggers` list. If the
		// dying entry were still present at that point, revalidate_triggers()
		// would independently discover it is ineligible and cancel it a second
		// time -- a duplicate trigger_canceled notification for what is really
		// one event. Erasing first means a reentrant call only ever sees the
		// entry that replaced it, if any.
		//
		// Guard by the serial captured before the loop above ran: a callable
		// chain member's own CANCELED delivery inside that loop cannot recapture
		// this (scope, action) synchronously (it runs at dispatch_depth + 1, so
		// any Core call it makes is deferred), but this check is kept anyway so
		// this step's correctness does not depend on that always remaining true.
		const std::size_t at = find_trigger_index(p_trigger.scope, p_trigger.action);
		if (at < triggers.size() && triggers[at].serial == p_trigger.serial) {
			triggers.erase(triggers.begin() + static_cast<std::ptrdiff_t>(at));
		}
		if (!canceled.empty()) {
			invoker->on_trigger_canceled(p_trigger, p_time_usec);
		}
		return false;
	}

	// Same stale-identity hazard as above: only write the surviving chain back
	// if the trigger found at (scope, action) is still the one this call started
	// with, not a same-key trigger recaptured while a handler ran above.
	const std::size_t at = find_trigger_index(p_trigger.scope, p_trigger.action);
	if (at < triggers.size() && triggers[at].serial == p_trigger.serial) {
		triggers[at].chain = surviving;
	}
	p_trigger.chain = surviving;
	return true;
}

void Core::revalidate_triggers(TimeUsec p_time_usec) {
	if (invoker == nullptr || triggers.empty()) {
		return;
	}
	// Snapshot the identities of the triggers to check before cancelling any of
	// them. cancel_trigger_at() invokes invoker->on_trigger_canceled() after
	// already erasing its own entry, and that callback is arbitrary handler
	// code: it can call cancel_action()/cancel_device() and erase more entries
	// from `triggers`, which would invalidate a raw index captured before the
	// callback ran (this loop used to run from a bound captured once, which is
	// exactly that hazard). Re-finding by identity right before acting on each
	// one -- the same pattern tick() uses -- means a vanished entry is simply
	// skipped instead of read or erased out of bounds.
	std::vector<std::pair<ScopeKey, Id>> keys;
	keys.reserve(triggers.size());
	for (const TriggerState &trigger : triggers) {
		keys.emplace_back(trigger.scope, trigger.action);
	}

	// build_ranks() only depends on a scope's contexts/layers, which cannot
	// change synchronously while this pass is running: a handler invoked by
	// cancel_trigger_at()'s CANCELED delivery below is mid-dispatch (it brackets
	// its calls with ++dispatch_depth/--dispatch_depth), so any structural
	// mutation it triggers is deferred rather than applied immediately -- see
	// Core::apply(). Caching one ScopeRanks per distinct scope for the whole
	// pass, instead of rebuilding it for every trigger, turns this from
	// O(triggers) rebuilds into O(distinct scopes) without changing behaviour.
	std::unordered_map<ScopeKey, ScopeRanks, ScopeKeyHash> ranks_cache;

	// A state change may have made an entire captured chain ineligible, for
	// example because its context was suspended or its screen left the top of
	// its layer. Those sequences are cancelled eagerly rather than lazily.
	for (std::size_t i = keys.size(); i > 0; --i) {
		const auto &key = keys[i - 1];
		const std::size_t at = find_trigger_index(key.first, key.second);
		if (at >= triggers.size()) {
			// Already cancelled by a callback triggered earlier in this loop.
			continue;
		}
		const TriggerState &trigger = triggers[at];
		const ScopeState *state = find_scope(trigger.scope);
		if (state == nullptr) {
			cancel_trigger_at(at, p_time_usec);
			continue;
		}
		auto cached = ranks_cache.find(trigger.scope);
		if (cached == ranks_cache.end()) {
			cached = ranks_cache.emplace(trigger.scope, state->build_ranks()).first;
		}
		const ScopeRanks &ranks = cached->second;
		bool any_eligible = false;
		for (HandleId handle : trigger.chain) {
			if (Router::eligibility_of(*state, ranks, handle, *invoker) == Ineligible::NONE) {
				any_eligible = true;
				break;
			}
		}
		if (!any_eligible) {
			cancel_trigger_at(at, p_time_usec);
		}
	}
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

std::vector<ContextEntry> Core::active_contexts(const ScopeKey &p_scope) const {
	const ScopeState *state = find_scope(p_scope);
	if (state == nullptr) {
		return {};
	}
	std::vector<ContextEntry> result = state->all_contexts();
	// Highest priority first, most recently pushed breaking ties: the same order
	// build_ranks() uses, so a consumer sees what routing sees.
	std::sort(result.begin(), result.end(), [](const ContextEntry &a, const ContextEntry &b) {
		if (a.priority != b.priority) {
			return a.priority > b.priority;
		}
		return a.sequence > b.sequence;
	});
	return result;
}

std::vector<TriggerState> Core::captured_triggers(const ScopeKey &p_scope) const {
	std::vector<TriggerState> result;
	for (const TriggerState &trigger : triggers) {
		if (trigger.scope == p_scope) {
			result.push_back(trigger);
		}
	}
	return result;
}

std::vector<ActiveAction> Core::active_actions(const ScopeKey &p_scope) const {
	const ScopeState *state = find_scope(p_scope);
	if (state == nullptr || invoker == nullptr) {
		return {};
	}
	return Router::active_actions(*state, *invoker);
}

} // namespace cu
