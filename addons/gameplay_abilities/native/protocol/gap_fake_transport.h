#ifndef GAMEPLAY_ABILITIES_PROTOCOL_FAKE_TRANSPORT_H
#define GAMEPLAY_ABILITIES_PROTOCOL_FAKE_TRANSPORT_H

#include "core/ga_hash.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "protocol/gap_messages.h"

#include <cstdint>
#include <map>
#include <vector>

// Deterministic fake transport (task 11.2).
//
// This is the engine-independent harness every later networking,
// replication, and prediction test runs against (tasks 11.3/11.4 and
// whatever ability/prediction agents build on top of it). It moves opaque
// `std::vector<std::uint8_t>` envelopes between named endpoints and lets a
// test provoke exactly the network failure modes the networking spec
// requires the protocol to survive -- see "Deterministic Network
// Convergence" (scenario "Network duplicates and reorders deliveries") and
// "Ordered Authoritative Event Streams" in
// specs/gameplay-ability-networking/spec.md.
//
// Two properties make this a harness rather than a toy:
//   1. Zero wall clock, zero standard-library RNG. Time is `ga::Tick`,
//      advanced only by explicit `advance_to` calls. Randomness comes from
//      `DeterministicPrng`, seeded explicitly by the caller. A given
//      `(seed, script)` therefore produces byte-identical delivery order and
//      byte-identical (possibly corrupted) payloads on every platform, every
//      run -- exactly what task 11.4 needs to prove.
//   2. It never decodes gameplay content. Every payload is an opaque byte
//      vector in and out; the transport only ever inspects protocol-neutral
//      scalars (endpoint ids, ticks, byte lengths) it is responsible for
//      itself.
namespace ga::proto {

// ---------------------------------------------------------------------------
// DeterministicPrng
// ---------------------------------------------------------------------------

// A tiny explicit xorshift64* generator (Marsaglia's xorshift family; the
// "star" variant multiplies the shifted state by an odd constant before
// output to whiten the low bits). Chosen over `std::mt19937`/`std::rand`
// specifically because:
//   - it has NO global/static state -- two independently constructed
//     instances with the same seed produce the exact same output stream,
//     which is what lets two independent `FakeTransport` instances (or two
//     runs of the same test binary, on two different machines) agree bit
//     for bit;
//   - it advances by pure integer shift/xor/multiply, so the output does not
//     depend on the standard library implementation, the platform's
//     floating-point unit, or any environment/locale state -- only on the
//     64-bit seed and the exact sequence of calls made against it.
// Statistical quality and cryptographic strength are irrelevant here; only
// bit-for-bit reproducibility across platforms matters, and integer
// arithmetic on a fixed-width type gives that for free.
class DeterministicPrng {
public:
	// A seed of 0 is a fixed point of plain xorshift (it would stay 0
	// forever), so it is substituted with a fixed nonzero constant. This
	// keeps `DeterministicPrng(0)` well-defined and just as reproducible as
	// any other seed, rather than a silently-degenerate special case.
	explicit DeterministicPrng(std::uint64_t p_seed) :
			seed(p_seed),
			state(p_seed != 0 ? p_seed : 0x9E3779B97F4A7C15ULL) {}

	// Advances the generator and returns the next raw 64-bit value.
	std::uint64_t next_u64() {
		state ^= state >> 12;
		state ^= state << 25;
		state ^= state >> 27;
		return state * 0x2545F4914F6CDD1DULL;
	}

	// Uniform-ish integer in [0, p_bound). `p_bound == 0` always returns 0
	// without consuming a draw (there is nothing to choose among). The
	// modulo reduction has the usual small bias for a non-power-of-two
	// bound; acceptable here since this drives test scenarios, not a
	// statistically-audited simulation.
	std::uint64_t next_bounded(std::uint64_t p_bound) {
		if (p_bound == 0) {
			return 0;
		}
		return next_u64() % p_bound;
	}

	// Uniform-ish integer in [p_min, p_max] inclusive. Returns `p_min`
	// without consuming a draw if the range is empty/inverted (`p_max <=
	// p_min`) -- this is the fast path that keeps "no jitter configured"
	// (min == max == 0) from perturbing the RNG stream at all.
	std::uint64_t next_range(std::uint64_t p_min, std::uint64_t p_max) {
		if (p_max <= p_min) {
			return p_min;
		}
		return p_min + next_bounded(p_max - p_min + 1);
	}

	// True with probability p_permille/1000. `p_permille == 0` always
	// returns false WITHOUT consuming a draw, and `p_permille >= 1000`
	// always returns true without consuming a draw. This is what makes an
	// impairment axis structurally inert when its permille is 0 -- not just
	// statistically unlikely to fire, but incapable of firing, and it also
	// means turning one axis on/off never perturbs the draw sequence
	// another axis relies on.
	bool roll_permille(std::uint32_t p_permille) {
		if (p_permille == 0) {
			return false;
		}
		if (p_permille >= 1000) {
			return true;
		}
		return next_bounded(1000) < p_permille;
	}

	std::uint64_t seed_value() const { return seed; }

private:
	std::uint64_t seed;
	std::uint64_t state;
};

// ---------------------------------------------------------------------------
// Endpoints and channel reliability
// ---------------------------------------------------------------------------

// A transport-local endpoint identity. Deliberately a distinct type from
// `gap_authority.h`'s `PeerId` (also an `int32_t`): that file is owned by a
// concurrently-developed authority layer, and this harness has no gameplay
// dependency on it at all -- a `FakeTransport` endpoint is nothing more than
// "one side of a simulated link," useful for protocol/codec/replication
// tests that never need an `OwnershipTable`. `0` is reserved as "no
// endpoint," matching every other id-zero-is-invalid convention in this
// addon (see ga_ids.h).
using EndpointId = std::int32_t;
constexpr EndpointId INVALID_ENDPOINT_ID = 0;

// Whether a simulated link between two endpoints models the protocol's
// reliable-ordered channel (state-bearing commands, event batches,
// snapshots -- see design.md's "Protocol and replication") or an unreliable
// one. This is the switch that determines whether `TransportImpairment`'s
// `loss_permille` is even legal to configure (see below) and whether
// `FakeTransport` enforces per-sender delivery order.
enum class ChannelReliability : std::uint8_t {
	RELIABLE_ORDERED = 0,
	UNRELIABLE = 1,
};

// ---------------------------------------------------------------------------
// TransportImpairment
// ---------------------------------------------------------------------------

// The injection profile attached to one simulated link (both directions
// share one profile; see `FakeTransport::connect`). Every field is an
// integer -- no float/double anywhere, per the addon-wide "no floating point
// in deterministic paths" rule -- and every probability is a permille
// (parts-per-1000) in [0, 1000] so "always"/"never" are exact, representable
// integers rather than a floating-point 0.0/1.0 that could round
// differently on different hardware.
struct TransportImpairment {
	// Latency jitter added to a message's enqueue tick, drawn uniformly from
	// [latency_ticks_min, latency_ticks_max] via the transport's own
	// `DeterministicPrng`. Both zero (the default) means "no jitter": every
	// message is scheduled for delivery at the tick it was sent.
	std::uint64_t latency_ticks_min = 0;
	std::uint64_t latency_ticks_max = 0;

	// Probability (permille) that a sent message is delivered twice with
	// byte-identical content. See `FakeTransport::send`.
	std::uint32_t duplicate_permille = 0;

	// Probability (permille) that a sent message is deliberately deferred
	// behind the next message sent on the same (sender, receiver) direction,
	// producing a genuine, visible reorder. This is INDEPENDENT of the
	// latency-jitter reordering a naive per-message-independent delay could
	// cause; see `FakeTransport`'s class comment for how RELIABLE_ORDERED
	// channels stay in order even under jitter while still allowing this
	// field to force an explicit, test-requested reorder.
	std::uint32_t reorder_permille = 0;

	// Probability (permille) that a sent message is silently never
	// delivered. ONLY legal when the owning link's `ChannelReliability` is
	// `UNRELIABLE` -- `FakeTransport::connect` rejects a nonzero
	// `loss_permille` paired with `RELIABLE_ORDERED` with a `Status`,
	// because the protocol's correctness argument (see design.md's
	// "Protocol and replication" and the "Ordered Authoritative Event
	// Streams" requirement) depends on reliable-ordered delivery actually
	// being reliable in this harness. There is no way to configure loss on
	// a reliable channel by accident: the check runs once, at `connect`
	// time, for every link this class ever creates.
	std::uint32_t loss_permille = 0;

	// Probability (permille) that a sent message's bytes are mutated before
	// delivery. `max_corrupted_bytes` bounds how many distinct byte
	// positions are touched: this harness corrupts `min(max_corrupted_bytes,
	// message.size())` DISTINCT byte positions (never more, and never a
	// clamp-induced repeat of the same position), each position mutated to a
	// value guaranteed to differ from its original byte (an XOR with a
	// nonzero delta), and NEVER changes the message's length. Configuring
	// `corruption_permille > 0` with `max_corrupted_bytes == 0` is rejected
	// at `connect` time (there would be nothing to corrupt).
	std::uint32_t corruption_permille = 0;
	std::size_t max_corrupted_bytes = 0;

	// If not `ga::INVALID_TICK`, the link this impairment is attached to
	// stops delivering messages scheduled at or after this tick (see
	// `FakeTransport`'s class comment for the exact "hard link drop"
	// semantics and how this differs from the eager `disconnect()` call).
	Tick disconnect_at_tick = INVALID_TICK;
};

// ---------------------------------------------------------------------------
// Delivered messages and counters
// ---------------------------------------------------------------------------

// One message as it arrived in a receiver's inbox: exactly the bytes that
// were scheduled for it (already corrupted, if corruption was applied),
// tagged with enough provenance for a test to build a canonical delivery-log
// hash (see `FakeTransport::delivery_log_hash`) or to assert on ordering,
// duplication, and corruption directly.
struct DeliveredMessage {
	EndpointId sender = INVALID_ENDPOINT_ID;
	EndpointId receiver = INVALID_ENDPOINT_ID;
	Tick delivery_tick = 0;
	// Global send-order sequence number assigned when `send()` accepted the
	// underlying message (shared by a duplicate's own extra `send()`-style
	// scheduling call, so both copies of a duplicated message have distinct
	// but adjacent sequence numbers -- see `FakeTransport::send`).
	std::uint64_t enqueue_seq = 0;
	std::vector<std::uint8_t> bytes;
	bool was_duplicate = false;
	bool was_corrupted = false;
};

// Bounded-by-construction counters (plain integers, never a container that
// could grow without limit): how many messages this transport instance has
// sent, delivered, duplicated, reordered, dropped, and corrupted. Every
// field mirrors one of the six things the class comment's per-message
// pipeline can do to a message.
struct TransportCounters {
	std::uint64_t sent = 0;
	std::uint64_t delivered = 0;
	std::uint64_t duplicated = 0;
	std::uint64_t reordered = 0;
	std::uint64_t dropped = 0;
	std::uint64_t corrupted = 0;
};

// ---------------------------------------------------------------------------
// FakeTransport
// ---------------------------------------------------------------------------

// A deterministic, in-process simulated network. Every public method is a
// pure function of (current internal state, arguments, the next draws of
// the seeded `DeterministicPrng`) -- there is no wall clock, no thread, no
// I/O, so replaying the same sequence of calls against a freshly constructed
// `FakeTransport` with the same seed reproduces the exact same behavior on
// any machine.
//
// ---- Total delivery order (normative) ----------------------------------
// Every message this transport ever schedules is keyed by the 4-tuple
// `(delivery_tick, sender, receiver, enqueue_seq)`, compared lexicographically
// in that order (see `DeliveryKey` in the .cpp). Messages are stored in a
// `std::map<DeliveryKey, ...>`, so iteration order is the key's sort order,
// never insertion order or a hash bucket order -- two sends made in any
// order, or replayed on any platform, land in identical map position given
// identical keys. `enqueue_seq` is a transport-wide monotonic counter
// assigned the moment a message is accepted by `send()` (including the
// extra copy created by duplication), so it is a total order even between
// messages that land on the exact same tick between the same two endpoints.
//
// ---- Reliable-ordered enforcement (normative) --------------------------
// A RELIABLE_ORDERED channel must keep delivering each sender's messages, to
// a given receiver, in the order they were sent -- even while
// `latency_ticks_min/max` jitter is active (a naive "delay each message by
// an independently-drawn random amount" model would NOT guarantee this: a
// later message can easily draw a shorter delay than an earlier one). This
// class enforces it structurally, not probabilistically: every
// (sender, receiver) direction tracks `last_scheduled_delivery_tick`, and a
// freshly jittered candidate tick is always clamped up to
// `max(candidate, last_scheduled_delivery_tick)` before being committed, then
// that direction's watermark is advanced to the committed tick. Because this
// clamp runs unconditionally for every message (not only on
// RELIABLE_ORDERED channels -- it is simply harmless on an UNRELIABLE one,
// which promises no ordering anyway), a per-sender reorder can never happen
// by accident: it can only happen when `TransportImpairment::reorder_permille`
// is explicitly nonzero, which deliberately routes a message through the
// hold-and-flush mechanism described below INSTEAD of the clamp. There is no
// code path that reorders a message unless that field was explicitly
// configured nonzero by the test.
//
// ---- Explicit reorder injection -----------------------------------------
// When `reorder_permille` fires for a message being scheduled on some
// direction (sender, receiver), and that direction has no message already
// held back, the message is set aside (not yet committed to the delivery
// queue) instead of scheduled normally. It is released in one of two ways:
//   1. The NEXT message scheduled on the same direction (regardless of
//      whether it also rolls reorder) is committed at its own normal
//      clamped tick, and the held-back message is then committed at
//      `max(its own natural tick, that message's tick + 1)` -- strictly
//      after it. This is a genuine, visible swap: the held message (sent
//      first) is delivered after the message sent second. `reordered` is
//      only ever counted in this branch, when an actual swap is observed.
//   2. If no follow-up message ever arrives on that direction before
//      `advance_to` reaches the held message's own natural tick, `advance_to`
//      releases it at that natural tick with no swap (nothing to reorder
//      behind) -- a bounded safety net so a held message can never be
//      stuck forever. `reordered` is NOT incremented in this case.
// At most one message is ever held per direction (bounded state): if a
// direction already has a held message when another one rolls reorder, the
// new one is scheduled normally instead (it becomes the "next message" that
// flushes the existing hold).
//
// ---- Disconnect / reconnect policy (normative) --------------------------
// `disconnect(id)` models a hard, immediate link drop from `id`'s
// perspective: it marks the endpoint unreachable (`send()` to or from it
// then fails closed with `NETWORK_UNAVAILABLE`) and EAGERLY evicts every
// message currently sitting in the delivery queue (scheduled but not yet
// delivered) where `id` is the sender OR the receiver, in either direction,
// including anything currently held for reorder -- each eviction counts as
// `dropped`. Nothing "arrives late" after a disconnect; it is gone.
//
// `reconnect(id, new_session)` marks `id` reachable again under a brand new
// `SessionId` and EAGERLY evicts every currently queued (or held) message
// where `id` is the RECEIVER (not the sender -- see below) -- this is the
// structural enforcement of "old in-flight messages cannot be delivered
// into the new session" per the networking spec's reconnection scenario:
// nothing already in flight to `id` under its old identity can land in the
// inbox it will read from now on. Messages `id` had already sent to some
// OTHER endpoint before reconnecting are left alone (whether a peer other
// than the reconnecting one should still see them is that peer's own
// concern, not something a reconnect on `id` retroactively unwinds).
// `reconnect` may be called on an endpoint that was never explicitly
// disconnected, or never seen before at all (it is auto-registered); a
// disconnect is not a precondition for reconnecting.
//
// `TransportImpairment::disconnect_at_tick` is a different, LAZY rule
// attached to one specific link (both directions) rather than an eager
// action on an endpoint: any message scheduled for delivery at or after
// that tick on that link is dropped at actual delivery time inside
// `advance_to`, regardless of how large a single `advance_to` jump is (see
// below). A message already scheduled for a tick BEFORE the configured
// disconnect tick still arrives normally -- it "arrived" before the wire
// was cut.
//
// ---- advance_to is jump-size invariant -----------------------------------
// Calling `advance_to(T)` once must behave identically to calling it at
// every intermediate tick up to `T`: everything scheduled at or before `T`
// is delivered (or dropped per the rules above) exactly once, in the total
// order above, regardless of how large the jump from the current tick to
// `T` is. This holds because every rule above (the reliable-ordered clamp,
// the reorder hold, and the disconnect_at_tick check) is evaluated as a pure
// function of already-recorded state and each entry's own scheduled tick --
// nothing depends on how many separate `advance_to` calls were used to
// reach a given tick.
//
// ---- No wall clock, no unbounded growth from untrusted input -------------
// This harness's callers are always trusted, in-process test code
// constructing concrete byte vectors -- it is not on an untrusted-network
// input path the way gap_command_gate.h's trackers are, so it does not
// impose the kind of hostile-peer memory bounds those classes do. It is
// still bounded in every practical sense a test needs: at most one held
// message per direction, and the queue only ever holds what a test itself
// enqueued and has not yet drained.
class FakeTransport {
public:
	explicit FakeTransport(std::uint64_t p_seed);

	// ---- Topology --------------------------------------------------------

	// Creates (or reconfigures, if one already exists) a bidirectional link
	// between `p_a` and `p_b` sharing one `ChannelReliability` and one
	// `TransportImpairment` for both directions. Both endpoints are
	// implicitly registered as connected if not already known. Fails
	// closed, writing nothing, if:
	//   - `p_a == p_b`, or either equals `INVALID_ENDPOINT_ID` --
	//     StatusCode::INVALID_ARGUMENT.
	//   - `p_impairment.latency_ticks_max < p_impairment.latency_ticks_min`,
	//     or any `*_permille` field exceeds 1000 -- StatusCode::INVALID_ARGUMENT.
	//   - `p_impairment.corruption_permille > 0` with
	//     `p_impairment.max_corrupted_bytes == 0` -- StatusCode::INVALID_ARGUMENT
	//     (nothing would ever actually be corrupted).
	//   - `p_impairment.loss_permille > 0` with `p_reliability ==
	//     RELIABLE_ORDERED` -- StatusCode::NOT_SUPPORTED, detail =
	//     `p_impairment.loss_permille`. This is the one rule this class will
	//     never let a caller bypass: a reliable-ordered channel's
	//     correctness argument depends on it actually being reliable.
	// Reconfiguring an existing link only affects messages sent AFTER this
	// call; anything already scheduled keeps the tick it was already given.
	Status connect(EndpointId p_a, EndpointId p_b, ChannelReliability p_reliability, const TransportImpairment &p_impairment = TransportImpairment());

	// Hard, immediate link drop from `p_endpoint`'s perspective. See the
	// class comment's "Disconnect / reconnect policy" section for the exact
	// eviction rule. A no-op (but still marks the endpoint disconnected) if
	// `p_endpoint` was never referenced before.
	void disconnect(EndpointId p_endpoint);

	// Marks `p_endpoint` reachable again under a brand new session and
	// evicts stale inbound messages. See the class comment. Fails closed
	// with StatusCode::INVALID_ARGUMENT (no state changed) if
	// `p_endpoint == INVALID_ENDPOINT_ID` or `p_new_session ==
	// ga::proto::INVALID_SESSION_ID`.
	Status reconnect(EndpointId p_endpoint, SessionId p_new_session);

	bool is_connected(EndpointId p_endpoint) const;
	SessionId current_session(EndpointId p_endpoint) const;

	// ---- Transmission ------------------------------------------------------

	// Accepts `p_message` for delivery from `p_from` to `p_to` through
	// whatever link `connect()` configured between them, applying that
	// link's `TransportImpairment` in this fixed order: loss (UNRELIABLE
	// only) -> corruption -> scheduling (latency jitter + reliable-ordered
	// clamp + reorder hold) -> duplication (an independent second pass
	// through scheduling with byte-identical content). See the class
	// comment for the full ordering/reorder/disconnect rules.
	//
	// Fails closed, enqueuing nothing and touching no counters, if:
	//   - `p_from == p_to`, or either equals `INVALID_ENDPOINT_ID` --
	//     StatusCode::INVALID_ARGUMENT.
	//   - either endpoint is currently disconnected, or was never registered
	//     -- StatusCode::NETWORK_UNAVAILABLE.
	//   - no link was ever configured between `p_from` and `p_to` --
	//     StatusCode::NOT_FOUND.
	// A message accepted but subsequently lost to the loss impairment still
	// returns `ok_status()` (matching real fire-and-forget unreliable
	// transports: the call to send it did not fail, the packet did) and
	// still counts as `sent`.
	Status send(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_message);

	// ---- Time advancement / delivery ----------------------------------------

	// Delivers (or drops, per `disconnect_at_tick`) every message scheduled
	// at or before `p_target_tick`, in the total order documented on the
	// class, moving each into its receiver's inbox exactly once. A no-op if
	// `p_target_tick` is less than the tick this transport has already
	// reached (time never moves backwards). See the class comment for why
	// this call is invariant to how large a single jump is.
	void advance_to(Tick p_target_tick);

	// Drains and returns everything currently sitting in `p_receiver`'s
	// inbox, in delivery order. Returns an empty vector (never an error) for
	// an endpoint with nothing delivered yet.
	std::vector<DeliveredMessage> take_delivered(EndpointId p_receiver);

	// ---- Introspection --------------------------------------------------------

	// Full history of every message ever delivered by this instance, in
	// true delivery order, across every receiver combined. Unlike
	// `take_delivered`, this is never drained -- it is the canonical record
	// task 11.4's "identical bytes across repeated runs" proof hashes (see
	// `delivery_log_hash`).
	const std::vector<DeliveredMessage> &delivery_log() const { return log; }

	// FNV-1a 64-bit (ga_hash.h) over the canonical encoding of the full
	// `delivery_log()`: for each entry in order, its sender, receiver,
	// delivery tick, enqueue sequence, duplicate/corrupted flags, and the
	// length-prefixed message bytes. Two `FakeTransport` instances that
	// received the identical sequence of calls (same seed, same script)
	// always produce the identical hash; this is the single assertion task
	// 11.4 and the determinism tests below hash against, rather than
	// re-deriving the same canonical encoding ad hoc at every call site.
	std::uint64_t delivery_log_hash() const;

	Tick current_tick() const { return now_tick; }
	std::size_t pending_count() const { return queue.size(); }

	TransportCounters total_counters() const { return totals; }
	TransportCounters peer_counters(EndpointId p_endpoint) const;

private:
	struct EndpointState {
		bool connected = true;
		SessionId session = INVALID_SESSION_ID;
	};

	struct LinkConfig {
		ChannelReliability reliability = ChannelReliability::RELIABLE_ORDERED;
		TransportImpairment impairment;
	};

	// Unordered (a,b) key for per-link configuration (one config serves
	// both directions).
	struct UnorderedKey {
		EndpointId lo = INVALID_ENDPOINT_ID;
		EndpointId hi = INVALID_ENDPOINT_ID;
		bool operator<(const UnorderedKey &p_other) const {
			if (lo != p_other.lo) {
				return lo < p_other.lo;
			}
			return hi < p_other.hi;
		}
	};

	// Ordered (from,to) key for the per-direction reliable-ordered
	// watermark and reorder hold-back slot.
	struct DirectionKey {
		EndpointId from = INVALID_ENDPOINT_ID;
		EndpointId to = INVALID_ENDPOINT_ID;
		bool operator<(const DirectionKey &p_other) const {
			if (from != p_other.from) {
				return from < p_other.from;
			}
			return to < p_other.to;
		}
	};

	// A message set aside by the explicit-reorder mechanism, not yet
	// committed to the delivery queue.
	struct HeldMessage {
		std::vector<std::uint8_t> bytes;
		Tick natural_tick = 0;
		std::uint64_t enqueue_seq = 0;
		bool corrupted = false;
		bool duplicate = false;
	};

	struct DirectionState {
		Tick last_scheduled_delivery_tick = 0;
		bool has_hold = false;
		HeldMessage hold;
	};

	// Total delivery-order key: (delivery_tick, sender, receiver,
	// enqueue_seq), compared lexicographically in that order. See the class
	// comment's "Total delivery order" section.
	struct DeliveryKey {
		Tick delivery_tick = 0;
		EndpointId sender = INVALID_ENDPOINT_ID;
		EndpointId receiver = INVALID_ENDPOINT_ID;
		std::uint64_t enqueue_seq = 0;
		bool operator<(const DeliveryKey &p_other) const {
			if (delivery_tick != p_other.delivery_tick) {
				return delivery_tick < p_other.delivery_tick;
			}
			if (sender != p_other.sender) {
				return sender < p_other.sender;
			}
			if (receiver != p_other.receiver) {
				return receiver < p_other.receiver;
			}
			return enqueue_seq < p_other.enqueue_seq;
		}
	};

	struct QueuedEntry {
		std::vector<std::uint8_t> bytes;
		bool corrupted = false;
		bool duplicate = false;
	};

	EndpointState &endpoint_state(EndpointId p_id);
	const LinkConfig *find_link(EndpointId p_a, EndpointId p_b) const;
	TransportCounters &counters_for(EndpointId p_id);

	// Applies the reliable-ordered clamp / reorder-hold pipeline to one
	// logical transmission (the original send, or its duplicate) and either
	// commits it to `queue` or stashes it in that direction's hold slot.
	void schedule_send(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_bytes, bool p_corrupted, bool p_duplicate);
	void commit_entry(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_bytes, Tick p_tick, std::uint64_t p_seq, bool p_corrupted, bool p_duplicate);

	// Eagerly evicts (counts as dropped) every queued or held message
	// matching `p_predicate`. Shared by `disconnect`/`reconnect`.
	template <typename Predicate>
	void evict_if(Predicate p_predicate);

	std::uint64_t next_seq = 1; // 0 is never assigned, matching every other id-zero-is-invalid convention here.
	Tick now_tick = 0;
	DeterministicPrng prng;

	std::map<EndpointId, EndpointState> endpoints;
	std::map<UnorderedKey, LinkConfig> links;
	std::map<DirectionKey, DirectionState> directions;
	std::map<DeliveryKey, QueuedEntry> queue;
	std::map<EndpointId, std::vector<DeliveredMessage>> inboxes;

	std::vector<DeliveredMessage> log;
	TransportCounters totals;
	std::map<EndpointId, TransportCounters> per_peer;
};

// ---------------------------------------------------------------------------
// TransportScript
// ---------------------------------------------------------------------------

// One step in a replayable scenario. Every step names the tick it logically
// occurs at; `TransportScript::execute` advances the transport to that tick
// (a no-op if it is already there or in the past) before performing the
// step's action, so a script fully determines both the timeline AND the
// actions without the caller having to interleave separate `advance_to`
// calls by hand. Re-running the identical `TransportScript` against a fresh
// `FakeTransport` constructed with the same seed reproduces the identical
// outcome -- this is the exact mechanism task 11.4's "identical canonical
// snapshot bytes and hashes across repeated runs" proof drives.
enum class ScriptStepKind : std::uint8_t {
	CONNECT = 0,
	SEND = 1,
	ADVANCE_TO = 2,
	DISCONNECT = 3,
	RECONNECT = 4,
};

// A flat, fully-populated step record (no `std::variant` -- not in this
// addon's permitted core/protocol include set): only the fields relevant to
// `kind` are meaningful, the rest sit at their default. See
// `TransportScript::add_*` for which fields each kind uses.
struct ScriptStep {
	ScriptStepKind kind = ScriptStepKind::ADVANCE_TO;
	Tick tick = 0;
	EndpointId endpoint_a = INVALID_ENDPOINT_ID; // CONNECT: a. SEND: from. DISCONNECT/RECONNECT: endpoint.
	EndpointId endpoint_b = INVALID_ENDPOINT_ID; // CONNECT: b. SEND: to.
	ChannelReliability reliability = ChannelReliability::RELIABLE_ORDERED; // CONNECT only.
	TransportImpairment impairment; // CONNECT only.
	std::vector<std::uint8_t> message; // SEND only.
	SessionId new_session = INVALID_SESSION_ID; // RECONNECT only.
};

class TransportScript {
public:
	void add_connect(Tick p_tick, EndpointId p_a, EndpointId p_b, ChannelReliability p_reliability, const TransportImpairment &p_impairment = TransportImpairment());
	void add_send(Tick p_tick, EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_message);
	void add_advance_to(Tick p_tick);
	void add_disconnect(Tick p_tick, EndpointId p_endpoint);
	void add_reconnect(Tick p_tick, EndpointId p_endpoint, SessionId p_new_session);

	const std::vector<ScriptStep> &steps() const { return entries; }

	// Replays every step against `r_transport`, in recorded order. Each
	// step first calls `r_transport.advance_to(step.tick)` (a no-op if
	// already there or past it), then performs the step's action. A script
	// never short-circuits on a failing step -- it is a fixed plan, not a
	// short-circuiting program, so re-running it always performs the
	// identical sequence of calls regardless of any individual step's
	// outcome. Returns the LAST non-OK `Status` any step produced (`CONNECT`
	// and `RECONNECT` are the only kinds that can fail), or `ok_status()` if
	// every step succeeded.
	Status execute(FakeTransport &r_transport) const;

private:
	std::vector<ScriptStep> entries;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_FAKE_TRANSPORT_H
