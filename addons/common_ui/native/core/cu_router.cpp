#include "core/cu_router.h"

#include <algorithm>

namespace cu {

namespace {

// Decides whether one registration may be evaluated and, when it may, where it
// sits in the evaluation order.
Ineligible check_eligibility(const ScopeState &p_state, const ScopeRanks &p_ranks,
		const ActionRegistration &p_registration, const HandlerInvoker &p_invoker,
		int &r_context_rank, int &r_layer_rank, int &r_screen_rank) {
	if (p_registration.released) {
		return Ineligible::RELEASED;
	}
	if (!p_invoker.is_owner_valid(p_registration.owner)) {
		return Ineligible::OWNER_INVALID;
	}

	// Context. An unscoped registration sorts after every context-scoped one.
	if (p_registration.context == INVALID_ID) {
		r_context_rank = p_ranks.context_count;
	} else {
		auto rank = p_ranks.context_rank.find(p_registration.context);
		if (rank == p_ranks.context_rank.end()) {
			if (p_ranks.context_suspended.find(p_registration.context) != p_ranks.context_suspended.end()) {
				return Ineligible::CONTEXT_SUSPENDED;
			}
			return Ineligible::CONTEXT_INACTIVE;
		}
		r_context_rank = rank->second;
	}

	// Layer. A screen-scoped registration that omits its layer is resolved
	// through the stack that currently holds the screen.
	Id effective_layer = p_registration.layer;
	if (effective_layer == INVALID_ID && p_registration.screen != INVALID_OWNER) {
		effective_layer = p_state.layer_of_screen(p_registration.screen);
		if (effective_layer == INVALID_ID) {
			return Ineligible::SCREEN_INACTIVE;
		}
	}
	if (effective_layer == INVALID_ID) {
		r_layer_rank = p_ranks.layer_count;
	} else {
		auto rank = p_ranks.layer_rank.find(effective_layer);
		if (rank == p_ranks.layer_rank.end()) {
			return Ineligible::LAYER_INACTIVE;
		}
		r_layer_rank = rank->second;
	}

	// Screen. Only the routing-active top screen of a layer contributes
	// screen-scoped actions.
	if (p_registration.screen == INVALID_OWNER) {
		r_screen_rank = 1;
	} else {
		if (!p_invoker.is_owner_valid(p_registration.screen)) {
			return Ineligible::SCREEN_INACTIVE;
		}
		if (p_state.layer_of_screen(p_registration.screen) == INVALID_ID) {
			return Ineligible::SCREEN_INACTIVE;
		}
		if (p_state.top_screen(effective_layer) != p_registration.screen) {
			return Ineligible::SCREEN_NOT_TOP;
		}
		r_screen_rank = 0;
	}

	return Ineligible::NONE;
}

} // namespace

bool Router::candidate_precedes(const Candidate &p_a, const Candidate &p_b) {
	if (p_a.context_rank != p_b.context_rank) {
		return p_a.context_rank < p_b.context_rank;
	}
	if (p_a.layer_rank != p_b.layer_rank) {
		return p_a.layer_rank < p_b.layer_rank;
	}
	if (p_a.screen_rank != p_b.screen_rank) {
		return p_a.screen_rank < p_b.screen_rank;
	}
	if (p_a.priority != p_b.priority) {
		return p_a.priority > p_b.priority;
	}
	// Most recent registration wins; sequences are unique so the order is total.
	return p_a.sequence > p_b.sequence;
}

Ineligible Router::eligibility_of(const ScopeState &p_state, const ScopeRanks &p_ranks,
		HandleId p_handle, const HandlerInvoker &p_invoker) {
	const ActionRegistration *registration = p_state.find_registration(p_handle);
	if (registration == nullptr) {
		return Ineligible::RELEASED;
	}
	int context_rank = 0;
	int layer_rank = 0;
	int screen_rank = 0;
	return check_eligibility(p_state, p_ranks, *registration, p_invoker,
			context_rank, layer_rank, screen_rank);
}

RoutePlan Router::build_plan(const ScopeState &p_state, const ScopeRanks &p_ranks,
		const HandlerInvoker &p_invoker, Id p_action) {
	RoutePlan plan;
	for (const ActionRegistration &registration : p_state.all_registrations()) {
		if (p_action != INVALID_ID && registration.action != p_action) {
			continue;
		}
		int context_rank = 0;
		int layer_rank = 0;
		int screen_rank = 0;
		const Ineligible reason = check_eligibility(p_state, p_ranks, registration, p_invoker,
				context_rank, layer_rank, screen_rank);
		if (reason != Ineligible::NONE) {
			RouteEntry entry;
			entry.registration = registration.handle;
			entry.reason = reason;
			entry.order = -1;
			entry.invoked = false;
			plan.ineligible.push_back(entry);
			continue;
		}
		Candidate candidate;
		candidate.registration = registration.handle;
		candidate.action = registration.action;
		candidate.context_rank = context_rank;
		candidate.layer_rank = layer_rank;
		candidate.screen_rank = screen_rank;
		candidate.priority = registration.priority;
		candidate.sequence = registration.sequence;
		plan.ordered.push_back(candidate);
	}

	std::sort(plan.ordered.begin(), plan.ordered.end(), candidate_precedes);
	// Keep diagnostics reproducible as well.
	std::sort(plan.ineligible.begin(), plan.ineligible.end(),
			[](const RouteEntry &a, const RouteEntry &b) { return a.registration < b.registration; });
	return plan;
}

RouteReport Router::dispatch_press(const ScopeState &p_state, HandlerInvoker &p_invoker,
		Id p_action, const ScopeKey &p_scope, DeviceId p_device, TimeUsec p_time_usec) {
	RouteReport report;
	report.action = p_action;
	report.scope = p_scope;
	report.device = p_device;

	const ScopeRanks ranks = p_state.build_ranks();
	const RoutePlan plan = build_plan(p_state, ranks, p_invoker, p_action);
	report.entries = plan.ineligible;

	for (std::size_t i = 0; i < plan.ordered.size(); ++i) {
		const Candidate &candidate = plan.ordered[i];

		if (report.stopped) {
			RouteEntry entry;
			entry.registration = candidate.registration;
			entry.reason = Ineligible::ROUTING_STOPPED;
			entry.order = static_cast<int>(i);
			entry.invoked = false;
			report.entries.push_back(entry);
			continue;
		}

		HandlerCall call;
		call.registration = candidate.registration;
		call.action = p_action;
		call.phase = TriggerPhase::PRESSED;
		call.scope = p_scope;
		call.device = p_device;
		call.time_usec = p_time_usec;
		const RouteResult result = p_invoker.invoke(call);

		RouteEntry entry;
		entry.registration = candidate.registration;
		entry.reason = Ineligible::NONE;
		entry.order = static_cast<int>(i);
		entry.invoked = true;
		entry.result = result;
		report.entries.push_back(entry);

		if (is_consuming(result)) {
			report.consumed = true;
			report.chain.push_back(candidate.registration);
			if (result == RouteResult::HANDLED) {
				report.stopped = true;
			}
		}
	}

	return report;
}

std::vector<ActiveAction> Router::active_actions(const ScopeState &p_state,
		const HandlerInvoker &p_invoker) {
	const ScopeRanks ranks = p_state.build_ranks();
	const RoutePlan plan = build_plan(p_state, ranks, p_invoker, INVALID_ID);

	std::vector<ActiveAction> result;
	result.reserve(plan.ordered.size());
	for (const Candidate &candidate : plan.ordered) {
		const ActionRegistration *registration = p_state.find_registration(candidate.registration);
		if (registration == nullptr) {
			continue;
		}
		ActiveAction active;
		active.action = registration->action;
		active.registration = registration->handle;
		active.context = registration->context;
		active.layer = registration->layer;
		active.screen = registration->screen;
		active.priority = registration->priority;
		active.display_priority = registration->display_priority;
		active.show_in_action_bar = registration->show_in_action_bar;
		result.push_back(active);
	}
	return result;
}

} // namespace cu
