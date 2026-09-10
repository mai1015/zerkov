#ifndef WEAPON_SYSTEM_PROTOCOL_PREDICTION_H
#define WEAPON_SYSTEM_PROTOCOL_PREDICTION_H

#include "core/wpn_limits.h"

#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

// Presentation-only client-prediction bookkeeping (tasks.md 7.6; weapon-
// protocol spec, "Presentation-Only Client Prediction": "An owning network
// client MAY predict muzzle, animation, audio, crosshair, or reload
// presentation under documented bounds, but MUST NOT decrement canonical
// ammunition, complete reload, select a canonical hit, dispatch damage, or
// publish canonical noise before authority confirmation. Prediction SHALL
// remain reversible and keyed to a bounded command identity").
//
// PresentationPredictionTracker is engine-free and, structurally, CANNOT
// mutate canonical state: it has no WeaponRuntime or WeaponReplica member,
// no method that accepts one, and no method that returns anything but its
// own bounded PresentationIntent value type. A WeaponNetworkBridge (tasks.md
// 7.5, native/godot/weapon_network_bridge.h) owns one of these on its CLIENT
// role only, uses it purely to decide which bounded, intent-keyed
// presentation signal to emit next, and NEVER lets it touch the
// WeaponReplica it separately owns -- "restores the newest confirmed weapon
// snapshot" (the spec's rejection/divergence scenario) is therefore true by
// construction: the replica was never spent by a prediction, so it is
// already sitting at the newest confirmed snapshot the moment a rejection or
// divergence is observed. Only the bounded PRESENTATION cue this tracker
// remembers needs to be discarded or left alone -- never world or damage
// state, which this tracker (and the client bridge) has no path to touch at
// all.
namespace wpn::protocol {

enum class PredictionIntentKind : std::uint8_t {
	FIRE = 1,
	BEGIN_RELOAD = 2,
	CANCEL_RELOAD = 3,
	CONFIGURE_ATTACHMENTS = 4,
};

// One in-flight predicted command a client bridge is showing bounded
// presentation for, keyed by the SAME command_id/sequence the bridge already
// stamped on the real wire *Intent it sent (protocol/wpn_protocol_types.h).
struct PresentationIntent {
	std::string command_id;
	std::string instance_id;
	PredictionIntentKind kind = PredictionIntentKind::FIRE;
	// This intent's own command sequence -- resolved against a later
	// confirmed WeaponSnapshot::last_command_sequence (core/wpn_runtime.h),
	// NOT against the instance's revision (a command may be gameplay-
	// rejected, which still advances the admitted-sequence high-watermark
	// without producing a new live revision -- see
	// core/wpn_runtime.h::admit()'s doc comment).
	std::uint64_t sequence = 0;
	std::uint64_t sent_tick = 0;
};

enum class PredictionOutcomeKind : std::uint8_t {
	CONFIRMED = 1, // Authority's own confirmed sequence now covers this intent.
	REJECTED = 2, // An explicit CommandRejection named this exact command_id.
	DIVERGED = 3, // The instance's replica flagged resync (gap/impossible transition/explicit resync); this intent's true fate is unknowable from here, so it is discarded conservatively.
	EXPIRED = 4, // Evicted by capacity, or aged out past MAX_PRESENTATION_INTENT_AGE_TICKS, before ever resolving.
};

struct PredictionOutcome {
	PresentationIntent intent;
	PredictionOutcomeKind kind = PredictionOutcomeKind::EXPIRED;
};

class PresentationPredictionTracker {
public:
	// Records a freshly-sent command as pending presentation prediction.
	// Bounded by MAX_PENDING_PRESENTATION_INTENTS (wpn_limits.h): when
	// already at capacity, the OLDEST pending intent is evicted first
	// (returned via r_evicted, kind EXPIRED) -- this tracker never grows
	// without bound regardless of how many commands a game's client sends.
	void track(const PresentationIntent &p_intent, std::optional<PredictionOutcome> &r_evicted);

	// Called whenever a fresh confirmed WeaponSnapshot/WeaponDelta for
	// p_instance_id reports p_confirmed_sequence as its
	// last_command_sequence: resolves (CONFIRMED) every currently pending
	// intent for p_instance_id whose sequence is <= p_confirmed_sequence,
	// oldest first, and returns them. A no-op (empty result) if nothing
	// pending for this instance qualifies yet.
	std::vector<PredictionOutcome> confirm_up_to(const std::string &p_instance_id, std::uint64_t p_confirmed_sequence);

	// An explicit CommandRejection named p_command_id: removes and returns
	// it (kind REJECTED) if still pending; std::nullopt if it was already
	// resolved, expired, or was never tracked.
	std::optional<PredictionOutcome> reject(const std::string &p_command_id);

	// Divergence recovery (a replica-flagged resync, or an explicit
	// request_resync, for p_instance_id): every currently pending intent for
	// THAT instance is discarded (kind DIVERGED, since its true fate cannot
	// be determined without a fresh authoritative baseline) and returned.
	// Pending intents for any OTHER instance_id are left completely
	// untouched -- exactly the spec's "discard ... only bounded still-valid
	// presentation intents" scope: an intent for an instance that did NOT
	// diverge remains valid and simply stays pending (implicitly "replayed"
	// -- there is nothing to redo, its presentation cue keeps showing until
	// its own resolution arrives).
	std::vector<PredictionOutcome> diverge_instance(const std::string &p_instance_id);

	// Age-based bound: drops (EXPIRED) every pending intent whose sent_tick
	// is more than MAX_PRESENTATION_INTENT_AGE_TICKS behind p_now_tick,
	// oldest first, and returns them. Guards against a lost
	// acknowledgement/rejection stranding a presentation cue forever even
	// while comfortably under capacity.
	std::vector<PredictionOutcome> sweep_expired(std::uint64_t p_now_tick);

	std::size_t pending_count() const { return pending.size(); }
	bool is_pending(const std::string &p_command_id) const;

private:
	std::deque<PresentationIntent> pending; // ordered oldest-first by track() call order.
};

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_PREDICTION_H
