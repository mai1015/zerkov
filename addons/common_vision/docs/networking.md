# Authority and replicas

Common Vision's wire API moves one already-redacted observer projection from a
trusted authority to a read-only recipient. It is intentionally transport
neutral: the addon produces and validates `PackedByteArray` values, while your
game owns RPCs, authentication, peer-to-observer authorization, reliability,
rate limits, and retries.

## Ownership model

Use separate nodes on separate trust boundaries:

```text
trusted server                                      recipient client
┌──────────────────────────────┐                    ┌───────────────────────┐
│ SERVER_AUTHORITY world       │   authenticated    │ REPLICA world         │
│ full geometry                │   transport        │ one redacted observer │
│ all observers and targets    │ ─────────────────> │ projection only       │
│ per-observer private memory  │  snapshot/delta    │ no canonical queries  │
└──────────────────────────────┘                    └───────────────────────┘
```

Never send a packet merely because a peer supplied an observer ID. Resolve the
authenticated peer to an observer ID in server-owned authorization data, then
encode that observer. The packet is recipient-safe with respect to Common
Vision's projection, but the codec cannot determine whether you chose the right
recipient.

## What is on the wire

Both packet types contain exactly one complete observer projection:

- a **snapshot** can initialize or replace a replica;
- a **delta** carries the complete next projection plus an exact predecessor
  sequence.

“Delta” does not mean a field-level diff in API `0.1.0`. Its purpose is to prove
that no projection result was skipped. Wire sequence is the observer's
`result_revision`, which increments on every successful query even if visible
content did not change.

The first packet must be a snapshot. If the replica has sequence `N`, only a
delta `(predecessor=N, successor=N+1)` can apply. A gap latches resynchronization
and requires a strictly newer snapshot.

## Minimal local round trip

This complete example simulates transport by passing bytes directly. Replace
the two `deliver_*` calls with authenticated RPC or another bounded transport.

```gdscript
extends Node

const SNAPSHOT_REQUIRED := 8

var authority: CommonVisionWorld2D
var replica: CommonVisionWorld2D
var target_definition: Dictionary
var last_sent_sequence: int = 0


func _ready() -> void:
	authority = CommonVisionWorld2D.new()
	replica = CommonVisionWorld2D.new()
	add_child(authority)
	add_child(replica)

	require_ok(
		authority.configure(77, CommonVisionWorld2D.SERVER_AUTHORITY),
		"configure authority",
	)
	require_ok(
		replica.configure(77, CommonVisionWorld2D.REPLICA),
		"configure replica",
	)
	require_ok(authority.register_observer({
		"id": 5,
		"position": {"x": 0, "y": 0},
		"facing": {"x": 1_000_000, "y": 0},
		"range": 10_000_000,
		"full_circle": true,
		"memory_ticks": 3,
		"revision": 1,
	}), "register observer")

	target_definition = {
		"id": 9,
		"position": {"x": 2_000_000, "y": 0},
		"revision": 1,
	}
	require_ok(
		authority.register_target(target_definition),
		"register target",
	)

	# First completed projection: send a snapshot.
	require_ok(authority.query_observer(5, 1), "query tick 1")
	_send_snapshot()

	# Next completed projection: an exact-successor delta is allowed.
	var next_target: Dictionary = target_definition.duplicate(true)
	next_target["position"] = {"x": 3_000_000, "y": 0}
	next_target["revision"] = 2
	require_ok(authority.update_target(next_target, 1), "move target")
	target_definition = next_target
	require_ok(authority.query_observer(5, 2), "query tick 2")
	_send_delta_or_snapshot()

	var view: Dictionary = replica.get_replica_projection()
	require_ok(view, "read replica")
	assert(int(view["sequence"]) == 2)
	assert(int(view["result_revision"]) == 2)


func _send_snapshot() -> void:
	var packet: Dictionary = authority.encode_snapshot(5)
	require_ok(packet, "encode snapshot")
	_deliver_snapshot(packet.get("bytes", PackedByteArray()))
	last_sent_sequence = int(packet["sequence"])


func _send_delta_or_snapshot() -> void:
	var packet: Dictionary = authority.encode_delta(5, last_sent_sequence)
	if not packet.get("ok", false):
		if int(packet.get("code", -1)) == SNAPSHOT_REQUIRED:
			_send_snapshot()
			return
		require_ok(packet, "encode delta")

	_deliver_delta(packet.get("bytes", PackedByteArray()))
	last_sent_sequence = int(packet["successor_sequence"])


func _deliver_snapshot(bytes: PackedByteArray) -> void:
	var applied: Dictionary = replica.apply_snapshot(bytes)
	require_ok(applied, "apply snapshot")
	assert(applied.get("applied", false))


func _deliver_delta(bytes: PackedByteArray) -> void:
	var applied: Dictionary = replica.apply_delta(bytes)
	if int(applied.get("code", 0)) == SNAPSHOT_REQUIRED:
		var request: Dictionary = replica.request_resync()
		# Send request to the server through the game's authenticated transport.
		print("resync from sequence ", request.get("last_sequence", 0))
		return
	require_ok(applied, "apply delta")
	assert(applied.get("applied", false))


func require_ok(result: Dictionary, operation: String) -> void:
	assert(
		result.get("ok", false),
		"%s failed: code=%s diagnostic=%s detail=%s" % [
			operation,
			result.get("code", -1),
			result.get("diagnostic", -1),
			result.get("detail", 0),
		],
	)
```

In a real two-process integration, `last_sent_sequence` belongs in per-recipient
server connection state. Do not share one sequence cursor across observers.

## Server send algorithm

For each authenticated recipient:

1. Resolve its allowed observer ID on the server.
2. Complete that observer's authority query for the intended tick.
3. On first delivery, resync, or any skipped result, call
   `encode_snapshot(observer_id)`.
4. Otherwise call `encode_delta(observer_id, last_sent_sequence)`.
5. If encoding returns `SNAPSHOT_REQUIRED`, fall back to a snapshot.
6. Send only the returned `bytes`; retain the successful sequence in connection
   state.

Encoding reads the latest published projection. A target update alone does not
create a new packet sequence; query the observer first.

If a client requests resync with `last_sequence == N`, make sure the replacement
snapshot has a sequence greater than `N`. An initialized replica rejects an
equal or older snapshot. If the authority has not produced a newer projection,
complete another query before encoding the recovery snapshot.

## Client receive algorithm

For a snapshot:

1. Deliver bytes to `apply_snapshot()` on the correct `REPLICA` node.
2. Use the view only when `ok` and `applied` are true.
3. On success, a snapshot clears the resync latch.
4. On failure, retain the existing view; application is transactional.

For a delta:

1. Deliver bytes to `apply_delta()`.
2. If it succeeds, read `get_replica_projection()`.
3. If `code == SNAPSHOT_REQUIRED`, call `request_resync()` and send the returned
   descriptor through your transport.
4. Keep presenting the last good view if appropriate, but honor
   `resync_required`; do not pretend it is current.
5. Do not apply further dependent deltas while resync is latched. They are
   rejected until a newer snapshot succeeds.

`request_resync()` merely returns `{world_id, observer_id, last_sequence}` and
sets a local latch. It is not an RPC and contains no authentication proof.

## Binding rules

A replica is configured for one positive `world_id`. The first accepted
snapshot also binds it to one observer ID. Later packets must match both.

- wrong world: `INCOMPATIBLE`, prior view unchanged;
- different observer after binding: `INCOMPATIBLE`, prior view unchanged;
- stale/equal snapshot: `REVISION_MISMATCH`, prior view unchanged;
- delta before a snapshot: `SNAPSHOT_REQUIRED`, resync latched;
- duplicate/stale/gapped delta: rejected; a sequence gap latches resync;
- malformed, oversized, or incompatible packet: rejected transactionally.

To deliberately switch world or recipient, call `configure()` again. That
clears the previous binding, projection, and resync state.

## Inspecting without applying

`decode_snapshot()` and `decode_delta()` are read-only and valid on any role.
They are useful for diagnostics, capture inspection, and transport tests:

```gdscript
var decoded: Dictionary = replica.decode_snapshot(received_bytes)
if decoded.get("ok", false):
	print(
		"world=", decoded["world_id"],
		" sequence=", decoded["sequence"],
		" observer=", decoded["projection"]["observer_id"],
	)
```

Decoding successfully does not mean the packet is authorized for this peer or
applicable to this replica. `apply_*()` performs world/observer/freshness checks;
your transport must perform sender and recipient authorization.

## Security and privacy checklist

- Run canonical registration, geometry, and queries only on a trusted process.
- Treat observer ownership as authenticated server data.
- Never broadcast one observer's packet to unrelated peers.
- Put a transport-level size/rate limit in front of decoding; the codec itself
  rejects payloads over 16 MiB.
- Do not trust decoded IDs as permission to access other game systems.
- Check API, protocol, and algorithm versions during connection negotiation.
- Do not send the canonical target list beside a redacted vision projection.
- Present remembered actors from `last_known_position`, not a hidden live
  transform obtained through another replication channel.
- Keep the last good projection on rejection; never merge partially decoded
  records yourself.

The codec validates canonical shape, bounds, versions, and sequences. It does
not provide encryption, signatures, replay protection beyond projection
sequencing, or peer identity.

## Snapshot/delta result shapes

For exact fields, see the
[snapshot and delta API reference](api-reference.md#snapshot-and-delta-methods).
For recovery by status code, see
[Performance and diagnostics](performance-and-diagnostics.md#network-and-replica-failures).
