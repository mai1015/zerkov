#ifndef COMMON_UI_CORE_ROUTER_H
#define COMMON_UI_CORE_ROUTER_H

#include "core/cu_handler_invoker.h"
#include "core/cu_scope.h"
#include "core/cu_types.h"

#include <vector>

namespace cu {

// One eligible registration together with the sort key that places it in the
// documented evaluation order.
struct Candidate {
	HandleId registration = INVALID_HANDLE;
	Id action = INVALID_ID;
	int context_rank = 0;
	int layer_rank = 0;
	int screen_rank = 0;
	int priority = 0;
	std::uint64_t sequence = 0;
};

// Ordered evaluation plan for one scope, plus the reason every rejected
// registration was skipped.
struct RoutePlan {
	std::vector<Candidate> ordered;
	std::vector<RouteEntry> ineligible;
};

// Precedence, highest first:
//   1. matching UI user and Viewport (the caller selects the scope)
//   2. active contexts by descending priority, most recent entry breaking ties
//   3. active UI layers by descending priority
//   4. the top routing-active screen of each eligible layer
//   5. handler priority, most recent registration breaking ties
class Router {
public:
	// Builds the plan for p_action, or for every action when p_action is
	// INVALID_ID. Invokes nothing.
	static RoutePlan build_plan(const ScopeState &p_state, const ScopeRanks &p_ranks,
			const HandlerInvoker &p_invoker, Id p_action);

	// Runs a press through the plan and captures the consuming chain.
	static RouteReport dispatch_press(const ScopeState &p_state, HandlerInvoker &p_invoker,
			Id p_action, const ScopeKey &p_scope, DeviceId p_device, TimeUsec p_time_usec);

	// Immutable active-action snapshot in evaluation order.
	static std::vector<ActiveAction> active_actions(const ScopeState &p_state,
			const HandlerInvoker &p_invoker);

	static bool candidate_precedes(const Candidate &p_a, const Candidate &p_b);

	// Why p_handle would be skipped right now, or Ineligible::NONE. Used to
	// re-validate captured trigger chains between phases.
	static Ineligible eligibility_of(const ScopeState &p_state, const ScopeRanks &p_ranks,
			HandleId p_handle, const HandlerInvoker &p_invoker);
};

} // namespace cu

#endif // COMMON_UI_CORE_ROUTER_H
