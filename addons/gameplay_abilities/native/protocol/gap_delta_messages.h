#ifndef GAMEPLAY_ABILITIES_PROTOCOL_DELTA_MESSAGES_H
#define GAMEPLAY_ABILITIES_PROTOCOL_DELTA_MESSAGES_H

#include "core/ga_ability_component.h"
#include "core/ga_change_tracking.h"
#include "core/ga_delta.h"
#include "core/ga_targeting.h"

#include <cstdint>
#include <vector>

// Byte-vector wire entry points for the canonical delta codec (add-
// granular-delta-replication-2026-07-27, task 2.1-2.4). This file is the
// protocol-side half of the core/protocol split every sibling additive
// payload in this directory already follows (see `gap_task_messages.h`'s own
// file comment: "a recent additive payload done right"): ALL of the actual
// encode/decode/apply LOGIC lives in core, right alongside the
// `write_snapshot`/`restore_snapshot` pair it mirrors --
// `AbilityComponent::write_delta_batch`/`apply_delta_batch`
// (ga_ability_component.h) and each section's own per-record codec
// (`AttributeSet`, `TagContainer`, `EffectRuntime`, `AbilityTaskRuntime`,
// and `AbilityComponent`'s own grant/execution sections). This file only
// constructs the `SnapshotWriter`/`SnapshotReader` those core calls need and
// hands back/accepts plain `std::vector<std::uint8_t>` payload bytes -- the
// SAME shape `gap_task_messages.h`'s `encode_task_states`/`decode_task_states`
// already establish for a payload that does not yet have its own
// `MessageType`/byte-limit-table entry (task 5.2, explicitly a later wave --
// see this change's own task list, "NO wire activation": nothing here
// touches `ga::proto::MessageType`, `message_byte_limit`, `gap_handshake`,
// `ga_version` feature bits, or `GA_PROTOCOL_VERSION`). A later wave that
// wires this payload onto the event-batch stream frames these bytes through
// `gap_messages.h::encode_message`/`decode_message` exactly like every other
// payload already does; this file is deliberately silent about which
// `MessageType` that will be.
//
// Decoding is untrusted input, same convention as every file in this
// directory: `decode_and_apply_delta_batch` validates the ENTIRE batch
// (unknown section kinds, invalid record identities, out-of-bound operation
// counts and byte lengths -- spec "Delta Protocol Compatibility") before
// mutating `p_component`, by delegating straight to
// `AbilityComponent::apply_delta_batch`'s own validate-then-mutate
// contract; see that method's own doc comment for exactly what "before
// mutation" covers.
namespace ga::proto {

// Builds ONE canonical delta batch payload for `p_audience` from
// `p_component`'s CURRENT state -- see `AbilityComponent::write_delta_batch`'s
// own doc comment for `p_dirty`/`p_baseline`/`p_session_coordinator`'s exact
// contracts (this function forwards them unchanged). `p_byte_limit` bounds
// both the underlying `SnapshotWriter` and, together with
// `MAX_DELTA_SECTIONS_PER_BATCH`/`MAX_DELTA_RECORD_OPS_PER_SECTION`
// (ga_limits.h), the resulting payload; a batch that cannot fit fails
// closed (`StatusCode::PAYLOAD_TOO_LARGE`) with `r_bytes` left empty rather
// than silently truncated -- callers choosing a snapshot-fallback policy
// for an oversized batch are Wave 3's `ResyncTrigger::DELTA_OVERFLOW`
// (design.md), not this function.
Status encode_delta_batch(const AbilityComponent &p_component, ChangeAudience p_audience,
		const std::vector<DirtyRecord> &p_dirty, const DeltaBaseline &p_baseline,
		const GameplayAbilityWorldCoordinator *p_session_coordinator, std::size_t p_byte_limit,
		std::vector<std::uint8_t> &r_bytes);

// Decodes AND applies `p_bytes` (as `encode_delta_batch` produced) onto
// `p_component`'s current (confirmed-baseline) state -- see
// `AbilityComponent::apply_delta_batch`'s own doc comment for the exact
// validate-then-mutate contract and the TARGET_SESSION/`p_session_coordinator`
// atomicity note this forwards unchanged. `p_byte_limit` re-validates
// `p_bytes.size()` before a single byte is interpreted (mirroring
// `decode_message`'s own "validate before touching payload bytes"
// convention), independent of whatever limit `p_bytes` was originally
// encoded under.
Status decode_and_apply_delta_batch(const std::vector<std::uint8_t> &p_bytes, std::size_t p_byte_limit,
		AbilityComponent &p_component, GameplayAbilityWorldCoordinator *p_session_coordinator);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_DELTA_MESSAGES_H
