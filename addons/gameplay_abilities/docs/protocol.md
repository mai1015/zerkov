# Protocol and Determinism Reference

The exact wire contract this addon implements today: protocol version, API
version, the content-manifest algorithm, the canonical codec, the message
envelope and handshake byte layouts, every byte-limit and bound constant, the
supported tick-rate range, the fixed-point representation, the identifier
grammar, the handshake compatibility matrix, and the security/exclusion
rules that govern all of it.

This document satisfies tasks.md 12.4 ("Record the exact packet limits,
supported tick-rate range, canonical codec, protocol version, and manifest
algorithm selected during implementation") and the protocol/security/platform
slices of 12.3. It is written from `native/core/`, `native/protocol/`, and
`native/godot/gameplay_ability_network_bridge.h/.cpp` as they exist right
now, not from the delta specs' intent — see "Known discrepancies" at the end
for the few places worth calling out explicitly. For build/test/CI status
and the verified/planned state of each platform artifact, see
[`verification.md`](verification.md); this document does not repeat that
material. For the game-layer ENet/LAN-discovery transport, see
[`examples/gameplay_abilities/net/README.md`](../../../examples/gameplay_abilities/net/README.md);
that transport is entirely outside the addon core and is not repeated here
either.

## What exists today

Every mechanism described in this document is implemented and exercised
end-to-end — not just unit-tested in isolation — and covered by
`native/tests/ga_test_protocol.cpp`, `ga_test_primitives.cpp`,
`ga_test_version.cpp`, `ga_test_event_stream.cpp`, `ga_test_authority.cpp`,
`ga_test_transport.cpp`, `ga_test_change_tracking.cpp`,
`ga_test_delta_codec.cpp`, `ga_test_delta_parity.cpp`,
`ga_test_replication_gate.cpp`, `ga_test_heartbeat.cpp`,
`ga_test_wire_public_delta.cpp`, `ga_test_delta_conformance.cpp`,
and the cross-subsystem
`native/tests/ga_test_conformance.cpp` (see
[`conformance.md`](conformance.md)). Concretely, that is:

- The message envelope (`gap_messages.h/.cpp`) and its per-`MessageType`
  byte-limit table.
- The handshake request/response DTOs and the fail-closed compatibility
  check (`gap_handshake.h/.cpp`), now wired to a **live** content manifest —
  see "Handshake fingerprints are live" below.
- Stable network identity scope tracking (`gap_identity.h/.cpp`).
- Server-controlled ownership and permission (`gap_authority.h/.cpp`'s
  `OwnershipTable`), the untrusted-command choke point
  (`gap_command_gate.h/.cpp`'s `CommandSequenceTracker` / `RateLimiter` /
  `StrikePolicy` / `CommandGate`), ordered authoritative event streams
  (`gap_event_stream.h/.cpp`), and late-join/resync
  (`gap_resync.h/.cpp`'s `ResyncCoordinator`). `GameplayAbilityNetworkBridge`
  calls `CommandGate::admit` before touching any gameplay state on an
  inbound activation command, and drives `ResyncCoordinator`/
  `ClientEventStream`/`SnapshotEnvelope` for every server push and client
  apply — these are not standalone classes waiting for a caller.
- Message **bodies**, not just the envelope: `EventBatchHeader` (44 bytes),
  `ResyncRequest` (21 bytes), and `SnapshotEnvelope` (44 fixed + N payload
  bytes) all have defined field layouts in `native/protocol/`. The
  gameplay-content wire shapes for `ACTIVATION_COMMAND` and
  `COMMAND_ACK`/`COMMAND_REJECT` are defined one layer up, in
  `native/godot/gameplay_ability_network_bridge.cpp`. See "Message bodies"
  below for every layout.
- Every deterministic primitive the protocol layer depends on: fixed-point
  (`ga_fixed.h`), ticks (`ga_tick.h`), identifiers (`ga_identifier.h`),
  content/runtime ids (`ga_ids.h`), the content manifest
  (`ga_manifest.h`), canonical bytes/hash (`ga_bytes.h`, `ga_hash.h`), and
  transactions/snapshots (`ga_transaction.h`, `ga_snapshot.h`).
- Rate limiting (`MAX_COMMANDS_PER_SECOND`, `MAX_RESYNCS_PER_MINUTE`) is
  enforced, not reserved: `RateLimiter` is a real tick-based token bucket,
  consulted by `CommandGate::admit` on every inbound activation command and
  by `ResyncCoordinator::produce_for_request` on every explicit client
  resync request.
- Snapshots are real: every subsystem (`ga_tag_container.h`,
  `ga_attribute_state.h`, `ga_effect_runtime.h`, `ga_ability_component.h`)
  implements `write_snapshot`/`restore_snapshot`, composed into one
  canonical `AbilityComponent` snapshot that `GameplayAbilityNetworkBridge`
  sends as a `SnapshotEnvelope` and restores via `apply_snapshot_envelope`.
- Prediction and reconciliation are real: `ga_prediction.h`'s
  `PredictionJournal`/`PredictingComponent` and `ga_reconciliation.h`'s
  `PredictionHandleMap`/`PredictionReconciler`/`ServerTickEstimator` are
  driven by `GameplayAbilityNetworkBridge::request_activation_networked`,
  `feed_prediction_acknowledgement`, and `reconcile_and_resend` on every
  `NETWORK_CLIENT`-role bridge — see `ga_test_prediction.cpp` and
  `conformance.md`'s scenario 4.
- Per-audience change tracking, the canonical delta codec, change-gated
  sends with the bounded heartbeat, and sequenced observer delta streams
  (protocol 4, add-granular-delta-replication-2026-07-27) are real: an
  owner's `EVENT_BATCH` payload is a canonical granular delta, never a full
  snapshot; an idle component costs zero state bytes per tick; a peer whose
  cursor cannot be bridged by a delta falls back to a fresh `SNAPSHOT` under
  `ResyncTrigger::DELTA_OVERFLOW`. See "Delta payload layout", "Owner
  event-batch delta path and the `SNAPSHOT` fallback", "Change-Gated State
  Sends and Heartbeat", and "Sequenced observer delta streams" below.
- The reference ENet transport, cue forwarding, and snapshot/delta/
  public-state replication are driven by `GameplayAbilityNetworkBridge` and
  exercised across real OS processes by
  `tests/gameplay_abilities/network/run_multipeer_conformance.sh` (task
  11.3, extended by task 6.3 for delta-parity/idle-suppression/duplication-
  reorder/overflow-fallback coverage): a dedicated server plus three
  clients, a listen server plus one remote client, and a dedicated
  delta-replication conformance stage, all over real loopback ENet sockets,
  covering accepted and rejected prediction, induced-gap resynchronization,
  ownership spoofing, target rejection, malformed payloads,
  disconnect/reconnect, and late join — asserting every peer converges to
  byte-identical final snapshots through both the owner and observer delta
  paths. See [`verification.md`](verification.md)'s "Multi-peer conformance"
  section for the scenario-to-coverage table.

### Handshake fingerprints are live

`GameplayAbilityComponent::configure()` builds a real `ga::ManifestBuilder`
over every sealed definition registry (including target schemas and tag
reactions) and
exposes the result as `get_content_manifest_fingerprint()`.
`GameplayAbilityNetworkBridge::build_local_handshake()` reads that value
into both `content_manifest_fingerprint` and `identifier_dictionary_fingerprint`
on the outgoing `HandshakeRequest`/`HandshakeResponse`, and every SNAPSHOT
envelope stamps the same value into `manifest_fingerprint`. This closes what
used to be a real "nothing populates these at runtime" gap.

One deliberate pre-1.0 simplification remains here — not a bug, but worth stating
precisely:

- `identifier_dictionary_fingerprint` reuses the same value as
  `content_manifest_fingerprint` rather than a second, identifier-only hash
  from a live `IdentifierTable`. A genuine mismatch is still caught (both
  fields are compared independently by `evaluate_handshake`); this
  simplification only means a diagnostic cannot yet distinguish "identifiers
  differ" from "some other field differs." See the bridge's own file
  comment ("Deliberate pre-1.0 scope reductions").

**Tick rate now authoritatively lives on `GameplayAbilityComponent` (task
7.19).** `GameplayAbilityComponent::set_tick_rate()` is a pre-configuration
property, exactly like `role`/`entity_id`: immutable once `configure()`
succeeds, defaulting to `ga::DEFAULT_TICK_RATE` (60). `configure()` now
constructs its `ManifestBuilder` with THIS value, so
`manifest_tick_rate_difference_changes_fingerprint`'s guarantee (already
true at the `ga_manifest.h` API level) is finally exercised end-to-end
through the Godot layer: two components configured at different tick rates
produce different content-manifest fingerprints, and a handshake between
them fails, proven at the Godot layer by
`tests/gameplay_abilities/integration/test_component_runtime.gd`'s
`_test_tick_rate_changes_manifest_fingerprint_and_handshake` case.
`GameplayAbilityNetworkBridge` still exposes its own `tick_rate` property
(`set_tick_rate`/`get_tick_rate`) — used as a bootstrap value before a
served component has been resolved, and still what
`RateLimiter`/`CommandGate`/`ResyncCoordinator`/the handshake's own
`tick_rate` field/`_process()`'s local advisory clock read via the private
`effective_tick_rate()` helper — but once this bridge resolves a
*configured* served component, `effective_tick_rate()` defers to THAT
component's own `tick_rate` instead of the bridge's independently-settable
one, so there is exactly one tick rate in force for a wired session, never
two that can silently disagree. This closes the "component/bridge split"
that was this gap's root cause: previously the manifest and the handshake's
own `tick_rate` field could be built from two different values with no way
for either side to notice.

## Versioning

### Protocol version

`GA_PROTOCOL_VERSION` (`native/core/ga_limits.h`) is `4`, carried on the wire
as a `u16` in every message header and in every handshake DTO.

**Policy** (platform-support spec, "Pre-1.0 API and Protocol Policy"): the
protocol version increments whenever a change would alter **required packet
meaning or the canonical encoding** — i.e. a breaking change to anything this
document describes as wire layout. `decode_message` (`gap_messages.cpp`)
rejects any header whose `protocol_version` does not exactly equal the
running build's `ga::protocol_version()`
(`StatusCode::PROTOCOL_MISMATCH` / `DiagnosticId::PROTOCOL_VERSION_DIFFERS`) —
there is no forward- or backward-compatibility window.

**Pre-1.0 mixed-session rule** (platform-support spec): while the addon is
pre-1.0 (see below), old and new peers presenting different protocol
versions reject the mixed session explicitly during the handshake rather than
attempting a degraded/partial mode. `evaluate_handshake` enforces exactly
this: protocol version is the *first* field compared, and any mismatch is an
immediate, unambiguous failure (see "Handshake compatibility matrix" below).

Protocol 2 is the intentional breaking boundary for Ability Tasks and Typed
Targeting. It adds task input/state and target command/outcome/state message
types, task/session snapshot sections, typed target codecs, new negotiated
feature bits, and a 131,072-byte snapshot cap. A protocol-1 peer cannot
silently interpret or ignore those contracts and therefore fails closed.

Protocol 3 is the intentional breaking boundary for the observable-task
observer wire path (see "Task state visibility" below): `encode_public_state`'s
public payload gains an additive observable-task section, gated by the new
required `FeatureSet::OBSERVER_TASK_STATE` feature bit. A protocol-1 or
protocol-2 peer cannot silently interpret or ignore the widened public
payload and therefore fails the handshake closed, exactly like the
protocol-2 boundary above.

Protocol 4 (add-granular-delta-replication-2026-07-27) is the intentional
breaking boundary for granular delta replication: it changes the MEANING of
an owner `EVENT_BATCH` payload from a full canonical component snapshot to a
canonical granular delta (see "Delta payload layout" and "Owner event-batch
delta path and the `SNAPSHOT` fallback" below), replaces the observer's
per-tick unsequenced full public envelope with a sequenced public delta
stream built on the SAME codec, and adds one new message type
(`HEARTBEAT`). All of this is gated by the new required
`FeatureSet::DELTA_REPLICATION` bit, exactly like the protocol-2 and
protocol-3 boundaries above: a peer that cannot decode deltas would silently
misinterpret a delta payload as a full snapshot rather than failing safely,
so it fails the handshake closed instead. `ga_limits.h` gains five new
addon-internal (non-wire-shape, but still reviewable-in-one-place) bounds
governing the codec and send cadence — see "Complete limits table" below.

### API version

The addon's own public API version is `0.2.0`
(`GA_API_VERSION_MAJOR/MINOR/PATCH = 0/2/0` in `ga_limits.h`;
`ga::api_version_string()` formats it). It is carried in the handshake DTOs
as three separate `u8` fields but is **diagnostic-only** — `evaluate_handshake`
never compares it, so two builds differing only in patch/minor API version can
still connect if every wire-relevant field agrees.

**Pre-1.0 policy** (design.md "Public API and protocol versioning";
tasks.md 12.5): public classes, enums, serialized resource fields, packet
schemas, and the manifest algorithm are all versioned, and breaking pre-1.0
changes require migration notes plus an explicit protocol-incompatibility
bump where the change is wire-relevant. The API and protocol both stay
pre-1.0 until the reference vertical slice (Dash/Poison/Stun/Heal) **and** a
second representative game integration pass all conformance tests
(tasks.md 12.5). `0.2.0` remains actively pre-1.0, not a soft-frozen
`1.0` candidate.

## Manifest algorithm

`GA_MANIFEST_ALGORITHM = "fnv1a64-canonical-v1"` (`ga_limits.h`). This string
is exchanged in the handshake purely for diagnostics (see below) — it never
gates compatibility itself; the fingerprints it names do.

### The hash primitive

FNV-1a, 64-bit, defined in `ga_hash.h`:

```
offset (FNV1A64_OFFSET) = 0xcbf29ce484222325
prime  (FNV1A64_PRIME)  = 0x100000001b3
```

`Hasher::write_byte` is `state ^= byte; state *= prime;`, starting from
`offset`. Every multi-byte value is folded in **little-endian**, byte at a
time (`write_u16/u32/u64/i64`), so the digest never depends on host
endianness. `write_string` writes a `u16` length prefix before the UTF-8
bytes, so `"ab"+"c"` can never hash the same as `"a"+"bc"`.

This is the single hash used for the content manifest, snapshot digests
(`ga_snapshot.h`'s `SnapshotWriter`/`SnapshotReader`), and `IdentifierTable`
fingerprints — one algorithm, one implementation, reused everywhere a
fingerprint is needed.

### Two distinct fingerprints

The handshake carries two separately-named 64-bit fingerprints that must not
be confused:

1. **`identifier_dictionary_fingerprint`** — `IdentifierTable::fingerprint()`
   (`ga_ids.cpp`). Hashes the sorted `(identifier string, assigned dense id)`
   pairs. This proves both peers assigned identical dense ids to identical
   namespaced identifier strings.
2. **`content_manifest_fingerprint`** — `ContentManifest::fingerprint`, built
   by `ManifestBuilder::build()` (`ga_manifest.cpp`). Hashes, in canonical
   `(kind, identifier)` order, every registered definition's own canonical
   field bytes, then additionally mixes in `GA_PROTOCOL_VERSION`,
   `FIXED_SCALE`, and the session's tick rate. This proves both peers are
   running byte-identical *definition content* (not just identical names)
   under an identical protocol/numeric/tick configuration.

`ManifestEntryKind` (`ga_manifest.h`) fixes the primary sort key so appending
a new kind never reshuffles an existing fingerprint:

| Value | Kind |
|---|---|
| 0 | `TAG` |
| 1 | `ATTRIBUTE` |
| 2 | `EFFECT` |
| 3 | `ABILITY` |
| 4 | `CUE` |
| 5 | `TARGET_SCHEMA` |

`ManifestBuilder::entries` is a `std::map<(ManifestEntryKind, std::string), bytes>`,
so iterating it to hash already visits entries in canonical
`(kind, identifier)` order regardless of registration order
(`manifest_same_entries_different_order_same_fingerprint` in
`ga_test_primitives.cpp` proves this).

### `IdentifierTable::seal()` and dense-id determinism

`IdentifierTable` (`ga_ids.h`/`.cpp`) interns validated namespaced
identifiers but **does not** assign an id at `intern()` time — `r_id` is
always `INVALID_DEFINITION_ID` until `seal()` runs. `seal()` assigns dense
ids `1..N` by iterating `entries` (a `std::map<std::string, DefinitionId>`,
so already in ascending byte order per `identifier_less`) and numbering them
in that order. Two tables built from the same set of identifier strings —
interned in any order, on any peer — therefore assign identical ids to
identical names and produce an identical `fingerprint()`. This is proved by
`ids_canonical_order_independent_of_insertion_order` and
`proto_identity_definition_ids_agree_across_independently_built_tables`
(both in the test suite): two independently-built, independently-sealed
tables interning `"charlie.one"`/`"alpha.one"` in opposite orders still agree
on every assigned id.

Duplicate registration fails closed two ways: the same identifier string
twice (`StatusCode::DUPLICATE_DEFINITION`, `detail == 0`), or two *different*
identifier strings that happen to collide under the FNV-1a64 content hash
used for the table's internal collision index (`detail == <colliding hash>`)
— the table never silently favors one identifier over the other in that
case. See `determinism.md` for why this second path is implemented but not
unit-testable.

## Canonical codec

Rules, verbatim from `ga_bytes.h`:

1. **Integers are little-endian via explicit byte shifts, never object-representation copies.** Every writer method (`write_u16/u32/u64/i32/i64`) shifts and masks a byte at a time (`push_back(uint8_t(v & 0xFF)); v >>= 8;` in spirit); nothing ever `memcpy`s a struct or relies on host byte order. Readers reconstruct the same way (`read_u16` etc.), so encode/decode is architecture- and endianness-independent by construction — no `#ifdef` branches on host endianness exist anywhere in this path.
2. **Strings are length-prefixed and capped.** `write_string`/`read_string` use a `u16` byte length followed by raw UTF-8 bytes; both writer and reader reject a length over `MAX_STRING_BYTES` (128) — the writer marks itself failed rather than truncating, the reader fails closed with `DiagnosticId::BYTE_LIMIT_EXCEEDED` before assigning a single byte into the output string.
3. **Collections are count-prefixed and validated against both their declared limit and remaining bytes before any allocation.** `ByteWriter::write_count(count, limit)` fails if `count > limit` or `count > MAX_COLLECTION_COUNT` (4096). `ByteReader::read_count(count, limit, min_bytes_per_element)` fails the same way on the *encoded* side, and additionally rejects a count whose `count * min_bytes_per_element` exceeds the bytes actually remaining in the buffer (`DiagnosticId::TRUNCATED_PAYLOAD`) — a hostile count can never drive a `reserve()`/`resize()` call before this check has already refused it. `proto_allocation_bound_rejects_hostile_count_before_growth` and `proto_allocation_bound_rejects_count_exceeding_remaining_bytes` (`ga_test_protocol.cpp`) prove both halves of this explicitly, including asserting the output container's `.capacity()` stays `0` on rejection.
4. **Bools and enums are explicitly rejected outside their valid range.** `ByteReader::read_bool` reads a raw `u8` and fails with `DiagnosticId::INVALID_ENUM` for any value other than `0`/`1` — a malformed payload can never smuggle an out-of-range value into a bool-shaped field. Every enum decoded anywhere in this layer (`MessageType` via `is_valid_message_type`, the message header's `reserved` byte, snapshot section kinds) is range- or exact-match-checked the same way before use.
5. **Decoding treats every byte as untrusted.** `ByteReader::require()` checks remaining length before every primitive read; every multi-field decode (message header, handshake DTOs) checks each field in sequence and fails closed, resetting output parameters to their default/empty state, the moment any check fails — never a partially-filled result (`proto_decode_failure_never_partially_fills_output` proves this for both the envelope and the handshake DTO).

**Why this is architecture-, endianness-, and locale-independent:** every
multi-byte value crosses the wire as explicit octets assembled by shift/mask
arithmetic, so no platform's native integer representation, pointer width,
or byte order can change the bytes produced. `fixed_quantize` (the only path
a `double` may take into authoritative state — see below) rounds using pure
floating-point comparison and `std::floor`, never string formatting or
parsing, so it cannot pick up a locale's decimal separator. The identifier
grammar (below) is ASCII-lowercase-only, which removes locale-dependent case
folding and filesystem case-sensitivity differences from canonical state
entirely.

## Byte layouts

Read directly from `gap_messages.cpp` and `gap_handshake.cpp` — not inferred
from struct field order, since C++ struct layout is not the wire layout.

### Message envelope (`MESSAGE_HEADER_BYTES` = 12)

Little-endian, fixed width, fixed field order, never renumbered:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 2 | `protocol_version` | u16 | must equal `ga::protocol_version()` |
| 2 | 1 | `message_type` | u8 | `MessageType`; must be `< MESSAGE_TYPE_COUNT` (15) |
| 3 | 1 | `reserved` | u8 | MUST be `0`; a nonzero value is rejected, not ignored, so a future per-message flag a newer peer relies on can never be silently skipped by an older decoder |
| 4 | 4 | `session_id` | u32 | transport-level connection identity (`ga::proto::SessionId`), independent of `ga::EntityId` and never used as a gameplay identity |
| 8 | 4 | `payload_length` | u32 | exact byte count of the payload immediately following the header |

The payload follows immediately and must be **exactly** `payload_length`
bytes — no trailing bytes, no gap. `decode_message` validates, strictly in
this order, before touching a payload byte: buffer length ≥ 12,
`protocol_version` match, `message_type` validity, `reserved == 0`,
`payload_length` exactly equals bytes remaining (rejects both inflated *and*
deflated declared lengths), and `payload_length` within both the per-type
limit and the caller's own frame-size cap. Only after every one of those
checks passes does it copy payload bytes.

### Handshake request/response (identical layout; distinguished only by `MessageType`)

Little-endian, fixed width, one bounded trailing string:

| Offset | Size | Field | Type |
|---|---|---|---|
| 0 | 2 | `protocol_version` | u16 |
| 2 | 1 | `api_version_major` | u8 |
| 3 | 1 | `api_version_minor` | u8 |
| 4 | 1 | `api_version_patch` | u8 |
| 5 | 4 | `required_features` | u32 (`ga::FeatureSet` bitmask) |
| 9 | 4 | `tick_rate` | u32 |
| 13 | 8 | `fixed_point_scale` | i64 |
| 21 | 8 | `identifier_dictionary_fingerprint` | u64 |
| 29 | 8 | `content_manifest_fingerprint` | u64 |
| 37 | 4 | `max_command_packet_bytes` | u32 |
| 41 | 4 | `max_event_batch_bytes` | u32 |
| 45 | 4 | `max_snapshot_bytes` | u32 |
| 49 | 4 | `max_handshake_bytes` | u32 |
| 53 | 2+N | `manifest_algorithm` | u16 length, then N UTF-8 bytes; N ≤ `MAX_STRING_BYTES` (128) |

Fixed portion: **53 bytes** before the length-prefixed algorithm string.
`decode_fields` (the shared template both DTOs go through) rejects a buffer
larger than `MAX_HANDSHAKE_BYTES` (8192) before parsing a single field, reads
every field in order, and — critically — rejects any **trailing bytes** left
over after the last declared field is consumed
(`DiagnosticId::TRUNCATED_PAYLOAD`): a payload that decodes cleanly but has
extra bytes appended is treated as internally inconsistent, not silently
ignored.

`manifest_algorithm` and `api_version_*` are diagnostic-only fields — see
"Handshake compatibility matrix" below for exactly which fields *do* gate
compatibility.

## Per-`MessageType` byte-limit table

`message_byte_limit()` (`gap_messages.cpp`) maps every message type to an
existing `ga_limits.h` constant — this file never introduces a second
literal for a bound `ga_limits.h` already owns. Limits are payload-only
(header's 12 bytes are additional):

| `MessageType` | Value | Byte-limit constant | Bytes |
|---|---|---|---|
| `HANDSHAKE_REQUEST` | 0 | `MAX_HANDSHAKE_BYTES` | 8192 |
| `HANDSHAKE_RESPONSE` | 1 | `MAX_HANDSHAKE_BYTES` | 8192 |
| `ACTIVATION_COMMAND` | 2 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `COMMAND_ACK` | 3 | `MAX_DIAGNOSTIC_BYTES` | 256 |
| `COMMAND_REJECT` | 4 | `MAX_DIAGNOSTIC_BYTES` | 256 |
| `EVENT_BATCH` | 5 | `MAX_EVENT_BATCH_BYTES` | 4096 |
| `SNAPSHOT` | 6 | `MAX_SNAPSHOT_BYTES` | 131072 |
| `RESYNC_REQUEST` | 7 | `MAX_DIAGNOSTIC_BYTES` | 256 |
| `PRESENTATION_EVENT` | 8 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `TASK_INPUT_COMMAND` | 9 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `TASK_STATE` | 10 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `TARGET_COMMAND` | 11 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `TARGET_OUTCOME` | 12 | `MAX_COMMAND_PACKET_BYTES` | 1024 |
| `TARGET_STATE` | 13 | `MAX_SNAPSHOT_BYTES` | 131072 |
| `HEARTBEAT` | 14 | `MAX_DIAGNOSTIC_BYTES` | 256 |

`MESSAGE_TYPE_COUNT = 15`. Values are additive and never renumbered/reused —
a peer on an older or newer build must keep interpreting an already-shipped
value identically forever; a new type is appended at the next unused value.
`COMMAND_ACK`/`COMMAND_REJECT`/`RESYNC_REQUEST` reuse `MAX_DIAGNOSTIC_BYTES`
because they carry a handful of scalar ids plus at most one bounded
diagnostic, never a bulk gameplay payload; `PRESENTATION_EVENT` reuses
`MAX_COMMAND_PACKET_BYTES` because it is the same shape/size class as an
activation command. Task/target commands and outcomes reuse the command
bound; complete target-session state may accompany a snapshot-sized restore.
`HEARTBEAT` (protocol 4) also reuses `MAX_DIAGNOSTIC_BYTES` -- its real,
fixed payload is only `HEARTBEAT_PAYLOAD_BYTES` (16) bytes (see "Heartbeat"
below), far smaller than the 256-byte type limit, but it shares
`COMMAND_ACK`/`COMMAND_REJECT`/`RESYNC_REQUEST`'s shape/size class rather
than getting a dedicated, tighter constant of its own.

`proto_envelope_round_trip_every_message_type` round-trips every one of
these fifteen types at its own limit; `proto_envelope_decode_rejects_payload_exceeding_type_limit`
proves the per-type limit is enforced independently of the caller's overall
frame-size cap.

## Message bodies

The envelope above frames an opaque payload. Core protocol DTOs define
task and target command/state codecs in `gap_task_messages.*` and
`gap_target_messages.*` in addition to the framing/sequencing types below.
Gameplay-content adapters remain in
`native/godot/gameplay_ability_network_bridge.cpp`, the one place both
wire framing and Godot-facing gameplay values are in scope.

### `EventBatchHeader` (`EVENT_BATCH`, `gap_event_stream.h/.cpp`)

Exactly `EVENT_BATCH_HEADER_BYTES` (44) bytes, little-endian, immediately
followed by the opaque event payload:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 8 | `component` | u64 | raw `ga::EntityId` |
| 8 | 8 | `predecessor` | u64 | raw `ga::EventSeq` this batch builds on |
| 16 | 8 | `batch_end` | u64 | raw `ga::EventSeq` after applying; MUST equal `predecessor + event_count`, checked on encode AND decode |
| 24 | 8 | `authoritative_tick` | u64 | `ga::Tick` this batch was decided at |
| 32 | 4 | `event_count` | u32 | `1..MAX_EVENTS_PER_BATCH` (128) |
| 36 | 8 | `payload_fingerprint` | u64 | FNV-1a64 (`ga::hash_bytes`) over the payload bytes that follow |

`AuthoritativeEventStream` (server) assigns the sequence range and retains
up to `MAX_RETAINED_EVENT_BATCHES` (64) recent batches for catch-up;
`ClientEventStream` (client) is the fail-closed state machine that only
ever applies a batch whose `predecessor` equals its own confirmed sequence,
in canonical order, never speculatively — see `ClientEventStream::apply_batch`'s
own doc comment for the full gap/duplicate/conflict decision table.

### Delta payload layout (`ga_delta.h`, `gap_delta_messages.h/.cpp`, protocol 4)

Since protocol 4 (add-granular-delta-replication-2026-07-27), an owner
`EVENT_BATCH`'s opaque event payload is a canonical **delta batch**, never a
full component snapshot — see "Owner event-batch delta path and the
`SNAPSHOT` fallback" below for how it reaches the wire, and "Sequenced
observer delta streams" for the PUBLIC-audience analogue. A delta batch is
an ordered list of **section deltas**, one per touched `ChangeSection`
(`ATTRIBUTE`, `TAG_SOURCE`, `ABILITY_GRANT`, `ACTIVE_EXECUTION`,
`ACTIVE_EFFECT`, `ABILITY_TASK`, `TARGET_SESSION`), each framed through this
addon's own `SnapshotWriter`/`SnapshotReader` section nesting
(`GA_SNAPSHOT_KIND_DELTA_BATCH`=60 / `_DELTA_SECTION`=61 /
`_DELTA_RECORD_OP`=62, `ga_delta.h`) exactly like every other canonical
snapshot section already does — never a second framing convention. Encoding
goes through `ga::proto::encode_delta_batch`
(`AbilityComponent::write_delta_batch` underneath); decode-and-apply goes
through `ga::proto::decode_and_apply_delta_batch`
(`AbilityComponent::apply_delta_batch`), which validates the ENTIRE batch —
unknown section kinds, invalid record identities, out-of-bound operation
counts — before mutating anything.

**One section delta is either RECORD_OPS or FULL_REENCODE**
(`DeltaSectionMode`, `ga_delta.h`):

- `RECORD_OPS` (0): an ordered list of record operations, each an 8-byte
  stable identity (attribute id, tag source token, ability spec id,
  execution id, effect handle, task handle, or session id — whichever the
  section's own protocol identity is) followed by a 1-byte `DeltaOpKind`
  (`ADD`=0, `UPDATE`=1, `REMOVE`=2) and, for `ADD`/`UPDATE`, that record's
  full current content via the SAME per-record writer the section's own
  snapshot codec uses. `ADD` and `UPDATE` carry an IDENTICAL record body —
  applying either is the identical action, upsert this identity's content —
  so `apply_delta_batch` never branches on which of the two a given op is;
  the two stay distinct on the wire purely for diagnostics.
- `FULL_REENCODE` (1): that section's own existing snapshot-section bytes,
  verbatim — literally the same writer call a full snapshot's own section
  uses, so byte-identity to "the corresponding snapshot section" is
  structural, not a separately maintained promise.

**The mode choice is a deterministic function of two counts**
(`ga::choose_delta_section_mode`, `ga_delta.h`/`.cpp`), so the SAME dirty set
always chooses the SAME mode, on every platform and every run: given
`dirty_count` (identities touched in this section since the peer's cursor)
and `live_count` (that section's current live record count),

1. `dirty_count > MAX_DELTA_RECORD_OPS_PER_SECTION` (512) forces
   `FULL_REENCODE` — a `RECORD_OPS` delta could never legally declare this
   many ops, so re-encoding is the only representable choice.
2. otherwise, once `dirty_count` reaches `DELTA_SECTION_REENCODE_CHURN_PERCENT`
   (60) percent of `live_count`, `FULL_REENCODE` is chosen (a record op
   always carries strictly more per-entry overhead than that same record's
   row in the section's own compact snapshot layout, so past this much
   churn, re-encoding the whole section is never larger and is usually
   smaller).
3. `live_count == 0` with `dirty_count > 0` (every touched record is now
   gone) always re-encodes — cheaper than even one `REMOVE` op.
4. otherwise, `RECORD_OPS`.

A batch may declare at most `MAX_DELTA_SECTIONS_PER_BATCH` (7) section
deltas — one slot per `ChangeSection`, never more.

**`DeltaBaseline` is an explicit ADD-vs-UPDATE input, not a re-derived
fact.** The server keeps no full historical copy of a peer's last-confirmed
section content, only its last-confirmed revision cursor plus
`ChangeTracker`'s bounded ring of identities touched since then — a ring
entry never records prior content, only "this identity changed," so "did
this identity exist before these touches" is not recoverable from the ring
alone. A caller with no per-peer identity-existence bookkeeping (every
caller today) passes an empty `DeltaBaseline`, which labels every still-live
touched identity `ADD` rather than `UPDATE` — always a SAFE
over-approximation, since `apply_delta_batch` treats the two identically;
this only affects a diagnostic op tag, never applied state.

### Owner event-batch delta path and the `SNAPSHOT` fallback (`event_batch_fits_stream`, `gap_event_stream.h/.cpp`; `send_owner_event_batch`, `gameplay_ability_network_bridge.cpp`)

`GameplayAbilityNetworkBridge::send_owner_event_batch` (the owner's per-tick
"next state" push, called from `push_full_state` once a peer is already
synced) first runs the send-gate decision
(`ga::proto::decide_send_gate_action`, "Change-Gated State Sends" below) —
suppressed, heartbeat, or send. When it sends, it encodes ONLY the sections
touched since that peer's own cursor (`ga::proto::encode_delta_batch`,
"Delta payload layout" above), never the whole component. A legal,
fully-populated component's full snapshot still measures up to 60,067 bytes
(see `budgets.md`); the honest single-tick WORST-CASE delta — every
`AbilityComponent`-owned section simultaneously at its own documented
maximum, forcing `FULL_REENCODE` everywhere — measures 48,527 bytes
(`budgets.md`'s "Delta replication" table), still far above
`MAX_EVENT_BATCH_BYTES` (4,096). An ORDINARY tick's delta is far smaller: a
single changed attribute measures 62 bytes, an effect add+remove pair 132
bytes, a full ability activation with a cost and a cooldown effect 239 bytes
— see `budgets.md` for the measured "typical tick" compositions.

`send_owner_event_batch` consults `ga::proto::event_batch_fits_stream
(payload.size())` BEFORE calling `append_batch` at all — exactly the same
two-bound check the pre-delta full-snapshot-as-batch shape already required,
now applied to a delta payload instead:

1. the append bound `append_batch` (via `encode_event_batch`) itself
   enforces: `EVENT_BATCH_HEADER_BYTES` (44) + payload <=
   `MAX_EVENT_BATCH_BYTES` (4,096);
2. the framing bound `encode_message` additionally enforces once that
   encoded batch is wrapped in a wire message: `MESSAGE_HEADER_BYTES` (12) +
   encoded batch <= `message_byte_limit(EVENT_BATCH)` (also 4,096 today).

Bound (2) is strictly tighter than (1) by exactly `MESSAGE_HEADER_BYTES`, so
a payload of 4,041-4,052 bytes satisfies (1) but not (2). The stream's
sequence never advances for a batch that fails either bound — `append_batch`
itself never mutates on a failed call, and `send_owner_event_batch` never
calls `encode_message` before `append_batch` already succeeded — so a
batch that cannot fit can never leave the peer with a gap for a message
that was never sent (spec "Oversized state cannot stall the stream").

When the encoded delta does not fit (`encode_delta_batch` itself fails, or
`event_batch_fits_stream` returns `false`, or `append_batch`/`encode_message`
fails after all) — OR when the peer's own cursor has fallen off
`ChangeTracker`'s bounded ring (`ChangeTracker::cursor_overflowed`, depth
`MAX_CHANGE_REVISION_RING_DEPTH` = 64, so a correct delta could not even be
computed) — `send_owner_event_batch` does not touch `owner_stream` at all:
it falls back to `send_snapshot_to_peer(peer, ResyncTrigger::DELTA_OVERFLOW,
tick)`, an unconditional full `SNAPSHOT` message whose own limit
(`MAX_SNAPSHOT_BYTES` = 131,072) always has room for even the 48,527-byte
worst-case delta's underlying live state (37.0% of the bound — see
`budgets.md`). This keeps working every tick a component's churn stays this
large: `produce_unconditional` is never subject to `RateLimiter::admit_resync`
(see "ResyncCoordinator" below), so a peer pinned to worst-case churn pays
the same per-tick full-snapshot cost observers already pay on THEIR own
overflow path, rather than failing. `ResyncTrigger::DELTA_OVERFLOW` is
purely informational, exactly like every other trigger value — never
wire-encoded — so introducing it was not itself a protocol change (the wire
break is the protocol-4 bump/feature bit described above, not this
enumerator). `ResyncTrigger::BATCH_OVERFLOW` (the pre-delta trigger for the
identical "payload too large for the event-batch stream" condition, back
when the payload was always a full snapshot) is superseded by
`DELTA_OVERFLOW` as of this wave: `send_owner_event_batch` never produces it
any more, since an owner batch is never a full snapshot to begin with — the
enumerator itself is kept (additive, never renumbered/reused, matching every
other wire enum in this addon) purely so historical references to it stay
meaningful. `_rpc_snapshot`'s owner branch applies either fallback exactly
like any other unconditional resync regardless of the client's current
`ClientEventStream` state (including `SYNCED`), re-establishing the baseline
via `apply_snapshot_envelope`/`ClientEventStream::establish_baseline`.

### Change-Gated State Sends and Heartbeat (`gap_replication_gate.h/.cpp`, `gap_heartbeat.h/.cpp`)

**The server never sends a state-bearing message to a synced peer whose
audience revision is unchanged since that peer's last sent update.**
`ga::proto::decide_send_gate_action` (`gap_replication_gate.h`) is the pure,
engine-free decision every server push site (`send_owner_event_batch`,
`send_public_state`) reduces to once it already knows a peer's own
bookkeeping — four inputs (this peer's cursor revision, the audience's
current revision, whether the cursor has overflowed the change-history
ring, and ticks since this peer's last send on this channel), checked in
this order:

1. `p_cursor_overflowed` -> `SEND_SNAPSHOT_OVERFLOW` (see `DELTA_OVERFLOW`
   above).
2. `p_cursor_revision != p_current_revision` -> `SEND_STATE` (something
   changed; encode and send this audience's own state, then advance the
   peer's cursor to the revision just represented).
3. `p_ticks_since_send >= p_heartbeat_cadence` (and the cadence is nonzero)
   -> `HEARTBEAT`.
4. otherwise -> `SUPPRESSED` (nothing to send this tick).

**While suppressed, the peer instead receives a bounded heartbeat at most
every `HEARTBEAT_SUPPRESSED_CADENCE_TICKS` (30) ticks** — a fixed
`HEARTBEAT_PAYLOAD_BYTES` (16) byte payload, little-endian, never
renumbered:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 8 | `authoritative_tick` | u64 | `ga::Tick` this heartbeat was sent at |
| 8 | 8 | `stream_head_sequence` | u64 | raw `ga::EventSeq` — the head sequence of whichever single event stream serves the receiving peer (`owner_stream` for an owner, `public_stream` for an observer) |

Framed cost: `HEARTBEAT_PAYLOAD_BYTES` (16) + `MESSAGE_HEADER_BYTES` (12) =
**28 bytes**, measured through the real `encode_heartbeat` + `encode_message`
codecs (`budgets.md`'s "Delta replication" table) — amortized to under one
byte per tick while suppressed (28 bytes / 30 ticks ≈ 0.93 bytes/tick). A
heartbeat never carries state to apply — it can only feed the receiving
peer's `ga::ServerTickEstimator` (the SAME `observe(local_tick,
authoritative_tick)` call a snapshot's or event batch's own tick already
makes, so idle suppression never leaves the tick estimate unrefreshed
longer than exactly one `HEARTBEAT_SUPPRESSED_CADENCE_TICKS`-sized window)
and OBSERVE a gap (never resolve one): `_rpc_heartbeat` compares the
heartbeat's `stream_head_sequence` against the receiving `ClientEventStream`'s
own confirmed sequence and calls `mark_needs_snapshot()` if the heartbeat
reports a head strictly ahead of what this peer has confirmed — the SAME
quarantine a detected `SEQUENCE_GAP` on a real batch already triggers.
`HEARTBEAT_SUPPRESSED_CADENCE_TICKS` is derived from, not independent of,
`ga::ServerTickEstimator`'s own smoothing rule (`ga_reconciliation.h`):
setting the cadence equal to the estimator's snap threshold means an idle
stretch of any length never leaves the estimate stale for longer than that
threshold's own "still smoothable, don't snap" window.

### Sequenced observer delta streams (`send_public_state`, `encode_public_baseline`, `gameplay_ability_network_bridge.cpp`; task 3.3/4.2)

**Observers now use the SAME ordered, predecessor-declaring stream contract
owners already have**, replacing the pre-protocol-4 per-tick unsequenced
full `encode_public_state()` envelope. Each replicated component gets a
SECOND, independent `AuthoritativeEventStream`/`EventSeq` space
(`public_stream`) alongside the owner's own (`owner_stream`) — one
component, two audiences, two sequence spaces, matching `ChangeTracker`'s
own per-audience revision split. `send_public_state` runs the identical
send-gate decision as the owner path, one audience over (`ChangeAudience::
PUBLIC`, `public_stream`/`public_cursors` instead of
`owner_stream`/`owner_cursors`), with `DELTA_OVERFLOW`-triggered
`SNAPSHOT`s produced from `encode_public_baseline()` instead of
`encode_full_snapshot()`.

**The public baseline IS a canonical delta batch, not a bespoke snapshot
shape.** `encode_public_baseline()` marks every currently live identity in
`ATTRIBUTE`, `TAG_SOURCE`, and `ABILITY_GRANT` (the three PUBLIC-eligible
sections a mirror with no `ACTIVE_EXECUTION` can install) as dirty against
an empty baseline, which forces `choose_delta_section_mode` to pick
`FULL_REENCODE` for all three (100% churn) — the one section mode whose own
writer applies `AudienceVisibilityConfig` filtering, so it is safe to pass
EVERY live identity (including a hidden one) without pre-filtering: the
writer excludes it regardless. `ABILITY_TASK` deliberately never rides this
delta batch: a PUBLIC batch can never satisfy `apply_delta_batch`'s
cross-section parent-execution check, since `ACTIVE_EXECUTION` has no
PUBLIC exposure at all. This is what lets a public baseline and every later
public delta batch share ONE canonical decoder
(`decode_and_apply_delta_batch`, installed onto a client-side scratch
core-component mirror — `GameplayAbilityComponent::build_scratch_mirror()`)
rather than a second, bespoke interpreter — `encode_public_state()`/
`decode_public_state()`'s old Dictionary-shaped codec is kept, unused by
this send path, only because its bespoke shape is still documented and
cross-referenced by example elsewhere.

**The composed public wire payload is TWO concatenated parts**, framed by
`compose_public_payload`/`decompose_public_payload`
(`gameplay_ability_network_bridge.cpp`, bridge-local framing, never its own
`ga::proto::MessageType`):

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | `delta_len` | u32, little-endian, the byte length of the canonical delta portion that follows |
| 4 | `delta_len` | delta bytes | the canonical PUBLIC-audience delta batch (`encode_delta_batch`, `ATTRIBUTE`/`TAG_SOURCE`/`ABILITY_GRANT` only) |
| 4 + `delta_len` | remainder | observer-task section (optional) | present ONLY when something task-visible changed since this peer's last update; `ga::proto::encode_observer_task_section` — see "Task state visibility" above for that section's own record layout |

Absence of the observer-task portion (not merely an empty one) means "no
observable task changed since the last update" — the receiving bridge
leaves its own `confirmed_observable_tasks` untouched rather than clearing
it. A baseline's task section is ALWAYS present (even representing zero
tasks), since a baseline represents complete state. This payload rides
inside the SAME `SnapshotEnvelope`/`EVENT_BATCH` opaque payload slot either
message type already has — no new `ga::proto::MessageType` and no
`message_byte_limit` table change were needed for it.

**A detected gap on the public stream stops dependent delta application and
triggers resynchronization**, exactly like the owner stream: `_rpc_event_batch`'s
observer branch runs `public_client_stream->apply_batch` through the SAME
`ClientEventStream` state machine ("Ordered Authoritative Event Streams" —
predecessor checks, idempotent duplicate detection, gap-triggered
`NEEDS_SNAPSHOT`) as the owner branch, just against `public_stream`'s
sequence space and `public_mirror`'s decoded state instead of the served
component's own. Unlike the owner path, a failed observer apply never drives
`reconcile_and_resend` — an observer never predicts, so there is no
speculative local state to replay; `request_resync` alone is sufficient.

### `ResyncRequest` (`RESYNC_REQUEST`, `gap_resync.h/.cpp`)

Exactly `RESYNC_REQUEST_BYTES` (21) bytes:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 4 | `session` | u32 | `SessionId` |
| 4 | 8 | `component` | u64 | raw `ga::EntityId` |
| 12 | 8 | `confirmed_sequence` | u64 | raw `ga::EventSeq`; `0` == no confirmed baseline yet |
| 20 | 1 | `reason` | u8 | `ResyncReason`; must be a recognized value (`< RESYNC_REASON_COUNT` == 5) |

An explicit client request goes through `ResyncCoordinator::produce_for_request`,
which consults `RateLimiter::admit_resync` (`MAX_RESYNCS_PER_MINUTE`) and a
`StrikePolicy` before any snapshot production work happens — a flooding
peer never causes unbounded server work. Server-decided triggers (first
relevance, late join, reconnect under a new session, relevance regained) go
through `produce_unconditional` instead and are never rate-limited.

### `SnapshotEnvelope` (`SNAPSHOT`, `gap_resync.h/.cpp`)

`SNAPSHOT_ENVELOPE_FIXED_BYTES` (44) fixed bytes, then exactly
`payload.size()` raw payload bytes:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 8 | `component` | u64 | raw `ga::EntityId` |
| 8 | 8 | `authoritative_tick` | u64 | `ga::Tick` this snapshot was produced at |
| 16 | 8 | `valid_as_of` | u64 | raw `ga::EventSeq`; becomes the client's confirmed sequence on acceptance |
| 24 | 8 | `manifest_fingerprint` | u64 | the content-manifest fingerprint this snapshot's content was produced under |
| 32 | 8 | `payload_fingerprint` | u64 | FNV-1a64 over the payload bytes below |
| 40 | 4 | payload length | u32 | `<= MAX_SNAPSHOT_BYTES` |
| 44 | N | `payload` | bytes | opaque; the component/effects canonical snapshot content |

Encoding FAILS rather than truncates once `payload.size() > MAX_SNAPSHOT_BYTES`
— the structural enforcement of "Snapshot is too large" (see "Known
discrepancies" for the size this constant actually needed to grow to).
`apply_snapshot_envelope` (client) additionally checks that the envelope
names the right component and that `manifest_fingerprint` matches the
session's already-agreed content-manifest fingerprint before ever invoking
the opaque-payload applier.

### `CommandResultWire` (`COMMAND_ACK`/`COMMAND_REJECT`, `native/godot/gameplay_ability_network_bridge.cpp`)

Not a `native/protocol/` DTO — this is the bridge's own bounded codec, the
concrete implementation of the scope seam `gap_messages.h`/`gap_event_stream.h`/
`gap_resync.h` deliberately leave open for gameplay-command content (see
those files' own "SCOPE SEAM" comments). Fixed 46-byte header, then a
count-prefixed list of 8-byte handles:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 8 | `component` | u64 | raw `ga::EntityId` |
| 8 | 8 | `command_sequence` | u64 | raw `ga::CommandSeq` |
| 16 | 8 | `prediction_key` | u64 | raw `ga::PredictionKey` |
| 24 | 8 | `execution` | u64 | raw `ga::ExecutionId` |
| 32 | 2 | `status.code` | u16 | `ga::StatusCode` |
| 34 | 2 | `status.diagnostic` | u16 | `ga::DiagnosticId` |
| 36 | 8 | `status.detail` | u64 | |
| 44 | 2 | handle count | u16 | `<= MAX_PENDING_PREDICTIONS` (16) |
| 46 | 8×N | `authority_durable_handles` | u64[] | raw `ga::EffectHandle` values, one per 8 bytes |

Fixed portion: 46 bytes, plus up to `MAX_PENDING_PREDICTIONS × 8` = 128
bytes of handles (174 bytes worst case) — comfortably inside the
`MAX_DIAGNOSTIC_BYTES` (256) budget `message_byte_limit` reserves for
`COMMAND_ACK`/`COMMAND_REJECT`.

`authority_durable_handles` (task 8.11) is the new field beyond the base
identity/status shape: every durable (non-instant) effect handle a commit
produced that a predicting client would also have journaled a temporary
handle for — today, in practice, exactly "the cooldown effect's handle, if
this commit newly applied one." The server never learns or sends a
client's own *temporary* handle value; only the authoritative side of the
mapping crosses the wire. The receiving client zips this list,
positionally, against its own journaled temp handles
(`GameplayAbilityNetworkBridge::feed_prediction_acknowledgement`) to build
`ga::PredictionAck::temp_handles`/`authority_handles` before
`PredictionReconciler::handle_acknowledgement` maps them via
`PredictionHandleMap`. Empty for a `REJECTED` ack (nothing to map) or for a
role that never predicts. No protocol-version bump was needed to add this
field when it originally landed. It is now part of the protocol-2 contract
alongside task/target messages and the enlarged snapshot bound.

### Task state visibility (`TASK_STATE`, task sections of `SNAPSHOT`/`EVENT_BATCH`, observable-task section of the public payload)

`AbilityTaskRequest::visibility` (`ga::AbilityTaskVisibility`) is a per-task
authoring choice, not a per-peer one, and every encoder that ever writes task
state accepts an explicit `AbilityTaskVisibility p_max_visibility`/`p_audience`
argument naming the RECEIVING peer's role. `ga::task_visible_to`
(`ga_ability_tasks.h`/`.cpp` — exported, not a per-file duplicate) is the ONE
filter every task-state encoder obeys: the core snapshot section
(`AbilityTaskRuntime::write_snapshot`), the standalone `TASK_STATE` DTO codec
(`gap_task_messages.cpp`), and the observable-task section below
(`gap_task_messages.cpp`'s `select_observer_task_records`) all call the exact
same function:

| Task's own `visibility` | Included for `OWNER_ONLY` audience | Included for `OBSERVABLE` audience | Included for `INTERNAL` audience |
|---|---|---|---|
| `OWNER_ONLY` | yes | no | yes |
| `OBSERVABLE` | yes | yes | yes |
| `INTERNAL` | **no** | no | yes |

In prose: **`INTERNAL` tasks are never replicated to any remote peer,
including the task's own owner** — they exist only in the authoritative
snapshot/reconciliation baseline (`INTERNAL` is also every encoder's default
audience, so purely local uses — persistence, digest/consistency checks,
rollback baselines captured on authority — see everything unfiltered without
having to opt in). **`OWNER_ONLY` tasks replicate to the owning client only**
— `OWNER_ONLY` is also the request-level default, so an ability author gets
this (not silent non-replication) unless they choose otherwise.
**`OBSERVABLE` tasks are additionally eligible for observer-visible state**
on top of everything `OWNER_ONLY` already gets an owner.

The component snapshot section (`AbilityComponent::write_snapshot`'s
`p_task_audience` parameter, forwarded to `AbilityTaskRuntime::write_snapshot`)
is what `GameplayAbilityNetworkBridge::encode_full_snapshot` uses for every
owner-facing wire path — `send_snapshot_to_peer`'s and `_rpc_resync_request`'s
own `owner ? encode_full_snapshot() : encode_public_state()` branches, and
`send_owner_event_batch` (itself only ever invoked for an owning peer via
`push_full_state`) — all pass `OWNER_ONLY` there, so this covers first
relevance, ordinary event-batch replication, explicit resync, reconnect, and
late join uniformly. Local/authoritative uses of the same method (persistence,
`GameplayAbilityWorldCoordinator::state_fingerprint` digesting, rollback
capture before an owner-snapshot restore attempt) keep the `INTERNAL` default
and are unaffected.

**Observers receive `OBSERVABLE` task state through an additive section of
the public payload (protocol 3, `FeatureSet::OBSERVER_TASK_STATE`).**
`encode_public_state()` — the payload every non-owner peer actually
receives — appends a bounded observable-task section after its existing
attribute/tag/ability-grant summary; `decode_public_state()` mirrors it into
`public_state_updated`'s additive `observable_tasks` key (an `Array` of
`Dictionary` entries). The section carries an explicit **field whitelist**,
never a sanitized copy of `ActiveAbilityTask` — see `ObserverTaskRecord`
(`gap_task_messages.h`) and the "Observer-safe task record layout" table
below for exactly what does and does not exist in these bytes.

Selection is `ga::proto::select_observer_task_records`
(`gap_task_messages.h`/`.cpp`), which the bridge feeds every one of the
served component's active tasks (via `AbilityTaskRuntime::active_handles`/
`find`) and applies, in order:

1. `task_visible_to(task.request.visibility, AbilityTaskVisibility::OBSERVABLE)`
   — the SAME shared filter the table above documents; `OWNER_ONLY` and
   `INTERNAL` tasks never become candidates.
2. A **defensive authoritative-only check**: `task.provenance !=
   ChangeProvenance::AUTHORITATIVE` is excluded even though
   `encode_public_state` only ever runs on authority
   (`push_full_state` returns early for `ROLE_NETWORK_CLIENT`) — a
   predicted, unconfirmed task must never reach an observer even if that
   call-site guarantee ever regressed (spec "Predicted task is not shown to
   observers").
3. **Hidden-ability suppression**, consistent with the grant list: the
   bridge resolves a surviving candidate's owning ability identifier through
   `GameplayAbilityComponent::get_grant(task.spec)` — the exact lookup the
   grant-list section already performs — and OMITS the record entirely
   (never with a blanked identity) if that identifier is unresolvable or
   named in `hidden_ability_identifiers`. A blanked record would still
   telegraph "something is casting", which concealment exists to prevent.

`encode_observer_task_section`/`decode_observer_task_section`
(`gap_task_messages.h`/`.cpp`) are the canonical byte codec: a bare
count-prefixed record list appended directly to the writer already building
`encode_public_state`'s payload — no message header or version field of its
own (this section's compatibility is gated at the handshake by the required
feature bit below, not a per-section version tag). Records are sorted
ascending by task handle before writing, so two encodes of the same
underlying task set are byte-identical regardless of iteration order,
matching `encode_task_states`'s own canonical-ordering convention. Decoding
enforces the same conventions as every other section in this document:
record count bounded by `MAX_ACTIVE_ABILITY_TASKS` (32), a strictly
ascending/non-duplicate task handle, an in-range `kind`, and a non-empty
`ability_identifier` — any violation fails the WHOLE decode closed (no
partial `observable_tasks` list is ever surfaced).

#### Observer-safe task record layout

Not a fixed-size struct — `ability_identifier` is a length-prefixed string
(bounded by `MAX_STRING_BYTES`, 128) like every other name this addon
carries on the wire, so only the OTHER fields have fixed offsets:

| Offset | Size | Field | Type | Notes |
|---|---|---|---|---|
| 0 | 8 | `task` | u64 | raw `ga::AbilityTaskHandle` |
| 8 | 8 | `execution` | u64 | raw `ga::ExecutionId` |
| 16 | 2+N | `ability_identifier` | string | u16 length, then N UTF-8 bytes; `N <= MAX_STRING_BYTES`; never empty |
| 18+N | 1 | `kind` | u8 | `AbilityTaskKind`; must be `<= WAIT_TARGET_DATA` |
| 19+N | 8 | `start_tick` | u64 | `ga::Tick` this task began at |
| 27+N | 1 | `has_deadline` | bool | mirrors `AbilityTaskRequest::has_deadline` |
| 28+N | 8 | `deadline_tick` | u64 | the AUTHORED deadline tick when `has_deadline`; `0` otherwise |

Preceded by a `u16` record count (`<= MAX_ACTIVE_ABILITY_TASKS`); the whole
section is simply that count followed by this many records back to back.

**Deliberately absent, by construction (`ObserverTaskRecord` has no field
for any of these — not merely a value that happens to be zeroed):**
prediction keys, change provenance, command/input sequences, tag queries,
logical input identities, authority prediction keys, target schemas, and
`ActiveAbilityTask::due_tick` (`AbilityTaskRuntime`'s internal
`WAIT_TICKS`-only wakeup-scheduling detail — never a fact about the task's
own authored deadline, which `deadline_tick` above already carries
uniformly across every task kind). See
`task_protocol_observer_section_whitelist_omits_prediction_provenance_sequence_and_wait_condition_bytes`
(`ga_test_task_protocol.cpp`) for the direct byte-absence proof.

`ability_identifier` deliberately mirrors the public grant list's own
representation (a resolved identifier string, not a raw `DefinitionId`):
this addon's `AbilityRegistry` is a core-owned reference the protocol layer
has no handle to, so resolution can only happen where the registry actually
lives (the bridge's served component) — and representing it as a string
lets an observer correlate a task's owning ability against
`public_state_updated`'s own `granted_abilities` list directly, with hidden-
ability suppression applying identically to both.

#### `public_state_updated`'s additive `observable_tasks` key

Each `Dictionary` entry: `{task: int, execution: int, ability_identifier:
String, kind: int, start_tick: int, has_deadline: bool, deadline_tick: int}`
(`deadline_tick` is `-1` when `has_deadline` is `false`, matching this
addon's existing "-1 means not applicable" convention for optional tick
fields elsewhere in this same dictionary-building code). **As of protocol 4,
`public_state_updated` itself is change-gated, not per-tick** — see
"Change-Gated State Sends and Heartbeat" above: it fires only when
`apply_public_delta` actually installs a received baseline or delta batch,
which now only happens on a tick the server actually sent one, never on a
suppressed tick. The `observable_tasks` list's OWN content stays
current-state-only within whichever message it rides: a peer's first
`public_state_updated` after gaining or regaining relevance (always a
baseline) already reflects every currently active observable task, and the
section is present on a LATER delta-carrying message only when something
task-visible changed since that peer's last update (`build_full_public_dirty`
never marks `ABILITY_TASK`; the task section is appended separately — see
"Sequenced observer delta streams" above) — but whenever present, it is
always the WHOLE current observable-task list, never a per-task add/remove
diff. A task's entry disappears the tick its removal is next represented
(the tick after it reaches a terminal outcome, subject to the SAME
change-gating) — there is no historical replay of past starts or terminal
events, and no observer mutation path exists for this data.

Filtering only OMITS entries from the existing count-prefixed task list; it
never changes the section's field layout, so no protocol version bump is
needed to filter differently. A restoring reader tolerates the resulting
"gaps" in handle numbering exactly like it tolerates a normal not-yet-started
handle: the allocator's own next-value is always written in full (never
filtered), and restore only requires it to be at least the highest handle
actually present in that reader's view — seeing handles `{2, 5}` with an
allocator of `6` is indistinguishable, on the wire, from "handles 1, 3, 4 were
never visible to this audience" and "handles 1, 3, 4 do not exist yet";
either way restore accepts it.

A task with both `PREDICTION_SAFE` and `INTERNAL` visibility is rejected at
task-start/restore validation (`AbilityTaskRuntime::validate_request`,
`StatusCode::INVALID_ABILITY_TASK` / `DiagnosticId::INVALID_TASK_PAYLOAD`):
such a task could predict locally on the owning client, but `INTERNAL`
guarantees the owner never receives the authoritative snapshot/event needed
to confirm or roll back that prediction, so it could never reconcile.
`visibility` defaults to `OWNER_ONLY`, so this is additive over every
pre-existing prediction-safe task request.

### Effect target-context visibility (retained `TargetEffectContext`, effects section of `SNAPSHOT`/`EVENT_BATCH`)

An effect definition may set `retain_target_context` so its `ActiveEffect`
keeps the immutable `TargetEffectContext` it was applied with (schema/source/
target/ability/execution/session identity, plus the private
`canonical_intent`/`validated_result` payload — quantized aim positions, hit
data, candidate/rejected entities). That context carries its OWN
schema-declared `TargetResultVisibility` (`TargetSchemaDesc::visibility`,
copied in at apply time), independent of any task's own visibility above.
Every currently-retained context on one component shares a single byte
budget, `MAX_RETAINED_TARGET_CONTEXT_BYTES`, enforced at effect-application
time (fails closed, before any mutation, if applying would exceed it) —
see budgets.md Finding 5 and docs/targeting.md's security checklist.
`sanitize_target_effect_context(context, audience)` is the one filter every
encoder obeys, applying the same three-audience matrix `visible_to` already
uses for target-session state:

| Context's own `visibility` | Kept for `OWNER_ONLY` audience | Kept for `OBSERVABLE` audience | Kept for `INTERNAL` audience |
|---|---|---|---|
| `OWNER_ONLY` | yes | no | yes |
| `OBSERVABLE` | yes | yes | yes |
| `INTERNAL` | **no** | no | yes |

"Kept" means every identity field (`schema`, `schema_version`, `source`,
`target`, `ability`, `execution`, `session`, `authority_tick`, `target_rank`,
`accepted`, `target_status`, `visibility`) survives unconditionally; only the
private `canonical_intent`/`validated_result` payload is stripped to an empty
value of the same `kind` when the row/column says "no". A sanitized context
still has `present == true` and passes `validate_target_effect_context`, so
it decodes and re-encodes exactly like an unsanitized one — the SECTION
format never changes and no protocol version bump is needed.

**Own-vs-foreign source derivation.** Unlike task visibility (a single
audience value covers every task in the section), which `audience` column
applies is decided PER RETAINED CONTEXT, because a component's active
effects can be sourced by different attackers. `EffectRuntime::write_snapshot`
takes a `TargetResultVisibility p_target_context_audience` (default
`INTERNAL`, i.e. every pre-existing caller writes retained contexts
untouched — local persistence, digest/consistency checks, rollback
baselines). Any other value means this snapshot is being encoded for one
specific remote peer, and for each retained context:

- `context.source == this component's own entity` (a self-applied
  effect): the receiving peer owns this component and therefore owns that
  source too, so it is sanitized with the `OWNER_ONLY` audience — full
  fidelity unless the schema itself opted into `INTERNAL`.
- any other `context.source` (a foreign attacker): the receiving peer is
  only ever an OBSERVER of that attacker's private data, so it is sanitized
  with the `OBSERVABLE` audience — stripped unless the schema opted into
  `OBSERVABLE`.

`AbilityComponent::write_snapshot`'s own `p_target_context_audience`
parameter (alongside the pre-existing `p_task_audience`) forwards this
unchanged to `effects().write_snapshot()`, and
`GameplayAbilityNetworkBridge::encode_full_snapshot` — the same single
choke point `p_task_audience` uses for every owner-facing wire path
(`send_snapshot_to_peer`, `_rpc_resync_request`'s `owner` branch,
`send_owner_event_batch`) — passes `OWNER_ONLY` for both parameters
together. Without this, an owner-facing full snapshot of a component that
was hit by a foreign attacker's `OWNER_ONLY`-schema effect would otherwise
hand that attacker's exact canonical intent to the target's owning client at
full (`INTERNAL`-default) fidelity, regardless of the schema's own
visibility — the information-leak this fix closes.

**Known accepted edge: one peer owning both sides.** A single peer that owns
BOTH the attacker's component and the target's component still receives the
sanitized, foreign-source copy when `encode_full_snapshot` runs for the
TARGET component (`context.source` is the attacker, not this component's own
entity, from the target component's point of view) — conservative
over-sanitization, not a correctness bug. The same peer still gets full
fidelity from the attacker's OWN component snapshot, where
`context.source == owner` holds.

**Other owner-facing carriers audited, unaffected.** `PresentationEventWire`
(the cue-forwarding DTO in `gameplay_ability_network_bridge.cpp`) carries no
target-context field at all — only entity/handle/tick/cue-identifier
metadata — so a retained context never reaches either its owner-shaped or
observer-shaped cue wire copy. `encode_public_state()`, the payload every
non-owner peer receives, is the same hand-rolled attribute/tag/ability-grant
summary the task-visibility section above already notes has no task section;
it likewise has no effects section of any kind, so it cannot carry a
retained context either. The full snapshot payload
(`encode_full_snapshot`/`AbilityComponent::write_snapshot`) is the only
owner-facing carrier of retained effect target context, and is the only one
this fix needed to touch.

## Complete limits table (`native/core/ga_limits.h`)

Every bound the runtime enforces. These are part of the wire contract —
changing one changes the protocol version (see "Versioning" above).

### Versioning and numeric/timing constants

| Constant | Value | Meaning |
|---|---|---|
| `GA_API_VERSION_MAJOR` | 0 | public addon API major version |
| `GA_API_VERSION_MINOR` | 2 | public addon API minor version |
| `GA_API_VERSION_PATCH` | 0 | public addon API patch version |
| `GA_PROTOCOL_VERSION` | 4 | wire protocol version |
| `GA_MANIFEST_ALGORITHM` | `"fnv1a64-canonical-v1"` | content-manifest fingerprint algorithm id |
| `FIXED_SCALE` | 1,000,000 | fixed-point subunits per whole unit |
| `DEFAULT_TICK_RATE` | 60 | default gameplay ticks/second |
| `MIN_TICK_RATE` | 10 | minimum supported tick rate (inclusive) |
| `MAX_TICK_RATE` | 240 | maximum supported tick rate (inclusive) |

### Identifiers

| Constant | Value | Meaning |
|---|---|---|
| `MAX_IDENTIFIER_BYTES` | 128 | max byte length of a namespaced identifier |
| `MAX_IDENTIFIER_SEGMENTS` | 8 | max dotted segments per identifier |

### Authoring and runtime state bounds

| Constant | Value | Meaning |
|---|---|---|
| `MAX_QUERY_DEPTH` | 4 | tag query nesting depth |
| `MAX_QUERY_OPERANDS` | 32 | operands per query clause |
| `MAX_TAG_SOURCES` | 512 | tag source records per container |
| `MAX_ATTRIBUTES` | 128 | attributes per component |
| `MAX_MODIFIERS` | 256 | active modifiers per component |
| `MAX_ACTIVE_EFFECTS` | 128 | active effects per component |
| `MAX_ABILITY_GRANTS` | 64 | granted abilities per component |
| `MAX_ACTIVE_EXECUTIONS` | 32 | concurrent ability executions per component |
| `MAX_ACTIVE_ABILITY_TASKS` | 32 | active Ability Tasks per component |
| `MAX_ABILITY_TASKS_PER_EXECUTION` | 8 | active tasks owned by one execution |
| `MAX_TASK_TERMINAL_EVENTS_PER_TICK` | 128 | terminal task events dispatched per tick |
| `MAX_TASK_WAITS_PER_INDEX` | 32 | task waiters in one scheduler index |
| `MAX_TASK_PAYLOAD_BYTES` | 256 | one kind-specific task payload |
| `MAX_TASK_DEADLINE_HORIZON_TICKS` | 864000 | farthest allowed task deadline |
| `MAX_TASK_INPUTS_PER_TICK` | 128 | accepted task input attempts per tick |
| `MAX_EFFECT_MODIFIERS` | 32 | modifiers declared per effect definition |
| `MAX_GRANTED_TAGS` | 32 | tags granted per effect definition |
| `MAX_TARGETS_PER_COMMAND` | 32 | target-data entities per command |
| `MAX_SET_BY_CALLER` | 16 | set-by-caller fields per effect spec |
| `MAX_EVENT_RECURSION` | 8 | gameplay-event chain recursion depth |
| `MAX_PERIODIC_CATCHUP` | 64 | periodic executions processed per advance |
| `MAX_STACK_COUNT` | 999 | max stacks for one stacking effect |

### Typed targeting bounds

| Constant | Value | Meaning |
|---|---|---|
| `MAX_TARGET_SCHEMAS` | 128 | registered schemas per coordinator/catalog |
| `MAX_TARGET_HITS` | 32 | hits in one target value |
| `MAX_ACTIVE_TARGET_SESSIONS` | 16 | live sessions per coordinator |
| `MAX_TARGET_SESSIONS_PER_EXECUTION` | 4 | live sessions owned by one execution |
| `MAX_TARGET_SUBMISSIONS_PER_SESSION` | 128 | session command/submission cap |
| `MAX_TARGET_PROVIDER_WORK` | 256 | provider-reported work cap |
| `MAX_TARGET_BATCH_PARTICIPANTS` | 32 | authority components in one batch |
| `MAX_TARGET_VALUE_BYTES` | 2048 | canonical typed value cap |
| `MAX_TARGET_COORDINATE_RAW` | 1,000,000,000,000 | absolute canonical coordinate cap |
| `MAX_RETAINED_TARGET_CONTEXT_BYTES` | 12,288 | sum of every currently-retained `TargetEffectContext`'s encoded bytes on one component; enforced at effect-application preflight, not at snapshot-encode time — see budgets.md Finding 5 |

### Prediction bounds

| Constant | Value | Meaning |
|---|---|---|
| `MAX_PENDING_PREDICTIONS` | 16 | unacknowledged predicted commands per component |
| `MAX_PREDICTION_JOURNAL_OPS` | 256 | journaled prediction ops per component |
| `MAX_PREDICTION_AGE_TICKS` | 300 | ticks a predicted command may go unacknowledged before it is abandoned and the component falls back to server-confirmed behavior |

### Delta replication (add-granular-delta-replication-2026-07-27, protocol 4)

`MAX_CHANGE_REVISION_RING_DEPTH` is addon-internal server bookkeeping (never
appears in an encoded payload, changing it does not change
`GA_PROTOCOL_VERSION`); the other four ARE part of the wire contract, like
every other constant in this table.

| Constant | Value | Meaning |
|---|---|---|
| `MAX_CHANGE_REVISION_RING_DEPTH` | 64 | depth of `ChangeTracker`'s bounded per-component, per-audience dirty-revision ring; how many consecutive revision-advancing commits a peer may miss before its cursor falls off the ring and the server falls back to a full snapshot (`ResyncTrigger::DELTA_OVERFLOW`) |
| `MAX_DELTA_SECTIONS_PER_BATCH` | 7 | section deltas one delta batch may declare — one slot per `ChangeSection`, never more |
| `MAX_DELTA_RECORD_OPS_PER_SECTION` | 512 | record operations one `RECORD_OPS`-mode section delta may declare, enforced identically on encode (never emit more) and decode (fail closed past this) |
| `DELTA_SECTION_REENCODE_CHURN_PERCENT` | 60 | once a section delta's dirty-record count reaches this percentage of that section's live record count, `choose_delta_section_mode` picks `FULL_REENCODE` over `RECORD_OPS` |
| `HEARTBEAT_SUPPRESSED_CADENCE_TICKS` | 30 | how many consecutive suppressed authoritative ticks elapse between heartbeats sent to a synced peer whose audience revision is unchanged |

### Packet bounds

| Constant | Value | Meaning |
|---|---|---|
| `MAX_COMMAND_PACKET_BYTES` | 1024 | one activation command payload |
| `MAX_EVENT_BATCH_BYTES` | 4096 | one authoritative event batch payload |
| `MAX_SNAPSHOT_BYTES` | 131072 | full component/coordinator restore payload |
| `MAX_HANDSHAKE_BYTES` | 8192 | one handshake request/response payload |
| `MAX_STRING_BYTES` | 128 | any decoded string, anywhere |
| `MAX_DIAGNOSTIC_BYTES` | 256 | one bounded diagnostic message payload |
| `MAX_EVENTS_PER_BATCH` | 128 | events carried in one event batch |
| `MAX_COLLECTION_COUNT` | 4096 | hard ceiling on any encoded collection count, regardless of a caller's own tighter limit |

### Rate limits

| Constant | Value | Meaning |
|---|---|---|
| `MAX_COMMANDS_PER_SECOND` | 30 | per-peer, per-component command rate limit |
| `MAX_RESYNCS_PER_MINUTE` | 6 | per-peer resynchronization request rate limit |

## Supported tick-rate range

`DEFAULT_TICK_RATE = 60`, `MIN_TICK_RATE = 10`, `MAX_TICK_RATE = 240`
(inclusive range). `validate_tick_rate()` (`ga_tick.cpp`) rejects anything
outside `[MIN_TICK_RATE, MAX_TICK_RATE]` with
`StatusCode::NOT_SUPPORTED` / `DiagnosticId::TICK_RATE_UNSUPPORTED`
(`tick_validate_tick_rate_boundaries` proves the boundary values).

**The rate is immutable for a session.** `SessionTiming` is a plain value
(`{ tick_rate }`) set once; nothing in `ga_tick.h`/`.cpp` exposes a way to
change it after ticks have started converting. It participates in both
contracts that must agree across peers:

- **The handshake**: `tick_rate` is a `u32` field on both
  `HandshakeRequest`/`HandshakeResponse`, and `evaluate_handshake` rejects a
  mismatch with `StatusCode::MANIFEST_MISMATCH` /
  `DiagnosticId::TICK_RATE_UNSUPPORTED` (see the compatibility matrix below).
- **The manifest**: `ManifestBuilder::build()` mixes the constructor's
  `tick_rate` into the content-manifest fingerprint (alongside
  `GA_PROTOCOL_VERSION` and `FIXED_SCALE`), so a tick-rate difference changes
  `content_manifest_fingerprint` even if every definition byte is identical
  (`manifest_tick_rate_difference_changes_fingerprint` proves this).

## Fixed-point representation

`ga::Fixed` (`ga_fixed.h`) wraps a single **signed 64-bit** integer (`raw`).
Scale is `FIXED_SCALE = 1,000,000` subunits per whole unit. This is the
**only** numeric representation allowed in authoritative gameplay state.

- **Rounding**: every rounding operation (`fixed_mul`, `fixed_div`, the
  tick/second conversions in `ga_tick.h`, and `fixed_quantize`) rounds
  **half away from zero** — an exact `.5` fractional subunit rounds to the
  larger-magnitude representable value, identically for positive and
  negative operands, so every peer replays to the same integer regardless
  of platform. `fixed_round_to_int` and `ga_tick.h`'s `ticks_from_seconds`/
  `ticks_from_milliseconds` all implement this explicitly rather than
  delegating to a library rounding mode.
- **Overflow policy**: every checked entry point (`fixed_add`, `fixed_sub`,
  `fixed_mul`, `fixed_div`, `fixed_neg`, `fixed_abs`) detects
  overflow/underflow **before** it would occur and returns
  `StatusCode::ARITHMETIC_ERROR` with `DiagnosticId::OVERFLOW_DETECTED` (or
  `DiagnosticId::DIVIDE_BY_ZERO` for division/modulo by zero) instead of
  ever relying on signed-integer overflow, which is undefined behavior in
  C++. The one exception is `Fixed::from_int`, which **saturates** rather
  than erroring, by design — it exists for small literal constants like
  `Fixed::one()`, not for validating adversarial input; callers that must
  reject rather than saturate should route through `fixed_quantize` or
  `fixed_mul` instead.
- **The shared primitive**: `fixed_mul_div_round(x, y, z)` computes
  `round_half_away_from_zero(x * y / z)` over plain (not pre-scaled) 64-bit
  integers without ever relying on signed-overflow UB. It uses `__int128`
  where the toolchain defines it (`__SIZEOF_INT128__` — true for every
  GCC/Clang desktop, mobile, and wasm32/Emscripten target this addon ships
  for) and falls back to a portable manual 128-bit long-multiply/long-divide
  otherwise; both paths implement identical rounding and range rules. See
  `determinism.md` for the current verification status of the fallback
  path.
- **`fixed_quantize` is the only path a `double` may take into authoritative
  state.** It rejects NaN, ±infinity, and magnitudes outside the
  representable `int64` raw range with `DiagnosticId::VALUE_NOT_REPRESENTABLE`,
  and rounds half away from zero without ever going through locale-sensitive
  string formatting/parsing (`fixed_quantize_rejects_nan_and_infinity`,
  `fixed_quantize_rejects_out_of_range`, `fixed_quantize_representable_values`
  in `ga_test_primitives.cpp`). `fixed_to_double` is the inverse, but it is
  **editor/presentation convenience only** — a presentation-computed value
  must round-trip back through `fixed_quantize` before it may re-enter core
  simulation; nothing in `ga_fixed.h` enforces this at the type level, so it
  is a documented calling-convention rule, not a compiler-checked one.

Canonical serialization: `fixed_write`/`fixed_read` encode/decode the raw
`int64` via the same little-endian `write_i64`/`read_i64` primitive every
other signed 64-bit field uses; `fixed_hash` folds it into an FNV-1a64 digest
the same way.

## Identifier grammar

From `ga_identifier.h`/`.cpp` — `ga::validate_identifier()` is the single
implementation; everyone in the addon calls it, nobody reimplements it.

```
identifier = segment ('.' segment)+          -- at least two segments
segment    = [a-z][a-z0-9_]*
```

Bounds: total length ≤ `MAX_IDENTIFIER_BYTES` (128 bytes), segment count ≤
`MAX_IDENTIFIER_SEGMENTS` (8). The grammar is deliberately ASCII-lowercase
only — no locale-dependent case folding, no filesystem case-sensitivity
differences reaching canonical state.

**Content-author warning — flagged here because it has already tripped up
test authoring in this codebase:** the grammar requires **at least two
dotted segments**. A bare single-segment name such as `stance` can **never**
be a valid, registrable identifier — `validate_identifier("stance")` fails
with `DiagnosticId::IDENTIFIER_NOT_NAMESPACED` (segments == 1). Every tag,
attribute, effect, ability, cue, and target-data schema identifier needs a
namespace prefix: `stance.aggressive`, not `stance`. This is called out
explicitly in `ga_test_tags.cpp`'s own test-fixture comment:

> the identifier grammar requires >= 2 segments (see `ga_identifier.h`), so a
> bare one-segment root like "stance" can never itself be a valid,
> registrable identifier — "stance.aggressive" stands in for it here as the
> shortest valid namespace root a query can target.

If you need a bare-word-looking root tag, use its shortest two-segment form
(e.g. `stance.aggressive`) as the actual registrable identifier and treat the
bare word as informal shorthand only.

Ordering is plain byte comparison (`identifier_less`) — stable,
locale-independent, identical on every platform; this is the ordering
`IdentifierTable::seal()` and `ManifestBuilder::build()` both rely on for
cross-peer determinism (see "Manifest algorithm" above).

## Handshake compatibility matrix

`evaluate_handshake(remote, local, result)` (`gap_handshake.cpp`) runs
independently on each peer, from its own perspective: does `local` (this
build's own handshake fields) satisfy everything `remote` (the value just
received) requires? Checks run in this exact order; **the first mismatch
wins** — later checks never run once an earlier one fails, so exactly one
`reason` is ever reported:

| Order | Field(s) compared | `StatusCode` | `DiagnosticId` | `HandshakeIncompatibilityReason` |
|---|---|---|---|---|
| 1 | `protocol_version` | `PROTOCOL_MISMATCH` | `PROTOCOL_VERSION_DIFFERS` | `PROTOCOL_VERSION` |
| 2 | `required_features` via `ga::negotiate_features(local.required, remote.required)` | `PROTOCOL_MISMATCH` | `FEATURE_UNSUPPORTED` | `REQUIRED_FEATURE` (`missing_required_features` set to the exact unsupported bits) |
| 3 | `tick_rate` | `MANIFEST_MISMATCH` | `TICK_RATE_UNSUPPORTED` | `TICK_RATE` |
| 4 | `fixed_point_scale` | `MANIFEST_MISMATCH` | `MANIFEST_FINGERPRINT_DIFFERS` | `FIXED_POINT_SCALE` |
| 5 | `identifier_dictionary_fingerprint` | `MANIFEST_MISMATCH` | `MANIFEST_FINGERPRINT_DIFFERS` | `IDENTIFIER_DICTIONARY` |
| 6 | `content_manifest_fingerprint` | `MANIFEST_MISMATCH` | `MANIFEST_FINGERPRINT_DIFFERS` | `CONTENT_MANIFEST` |
| 7 | any of `max_command_packet_bytes` / `max_event_batch_bytes` / `max_snapshot_bytes` / `max_handshake_bytes` | `MANIFEST_MISMATCH` | `BYTE_LIMIT_EXCEEDED` | `PACKET_LIMITS` |

Note that `DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS` is reused across rows
4–6 — it is `HandshakeIncompatibilityReason`, not `DiagnosticId`, that
disambiguates *which* field actually differed.

**Not checked** (diagnostic-only fields, per the byte-layout comment above):
`manifest_algorithm` and `api_version_*`. Two builds may differ in patch/API
version or report a different algorithm name and still connect, provided
every field in the table above agrees.

**No partial compatibility mode is ever inferred.** `HandshakeResult` is
either fully `compatible == true` with `reason == NONE`, or
`compatible == false` with exactly one `reason` and a matching non-OK
`status` — there is no third "degrade gracefully" outcome anywhere in this
function. `proto_handshake_no_partial_compatibility_mode_exists`
(`ga_test_protocol.cpp`) proves this for every row in the table above, one
mutation at a time, plus the lone fully-compatible success path.

`negotiate_features` (`ga_version.cpp`) treats any bit set in `remote` but
not in `local` as unsupported, **including bits this build has never even
defined** — an unrecognized required feature is exactly as unsupported as a
recognized one this build lacks, so a forward-incompatible peer can never be
silently accepted (`version_negotiate_unknown_remote_bit_fails_closed`,
`proto_handshake_client_requires_unsupported_feature_rejected`).

## Security rules

From the design.md "Security and failure policy" section and the networking
spec's "Untrusted Payload Validation" requirement, as actually implemented
in `native/core/` and `native/protocol/` today:

- **All payloads are untrusted.** Every decode path in `ga_bytes.h`,
  `gap_messages.cpp`, and `gap_handshake.cpp` checks remaining length before
  each read and validates every field before it is used or trusted.
- **Validation happens before allocation.** `ByteReader::read_count`
  validates a decoded count against both its declared limit and the bytes
  actually remaining **before** a caller may `reserve()`/`resize()` against
  it (see "Canonical codec" above); no decoder in this layer allocates
  proportional to an unvalidated count.
- **Diagnostics are bounded, carry stable codes, and never carry untrusted
  strings or secrets.** `Status`/`StatusCode`/`DiagnosticId` (`ga_status.h`)
  are the only failure-reporting channel this layer uses — no exceptions, no
  logging inside core/protocol. `HandshakeResult.status` never carries
  client-supplied string content or anything beyond what both peers already
  exchanged in the clear during the handshake itself (a version number, a
  fingerprint, a byte limit, a feature mask) — see the "identifies the
  incompatible manifest without exposing secret state" scenario in the
  networking spec, and the diagnostic-detail assertions in
  `proto_handshake_ability_content_differs_rejected`.
- **No `ObjectID`, `RID`, node path, memory address, or resource UID is ever
  transmitted as identity.** `ga_ids.h`'s own module comment states this as
  a hard rule, and `gap_identity.h`'s `SessionScope` is the structural
  enforcement point: it has no "get or create" method anywhere on its API,
  so a decoder cannot manufacture a placeholder for an identity it has not
  been explicitly told is live by code that already owns the real object
  (`proto_identity_unknown_identity_creates_nothing` proves repeated
  validation of an unknown identity never registers it as a side effect).
  The only identities that cross the wire are a `ga::DefinitionId` (interned
  and sealed by an `IdentifierTable` from an authored string) or a scoped
  runtime `ga::Handle<Tag>` assigned by a session-local monotonic allocator
  with no relationship to any pointer or engine allocation order.

### Current explicit multiplayer exclusions

Per the networking spec's "Explicit Multiplayer Exclusions" requirement,
the current pre-1.0 runtime
does **not** implement or advertise:

- Full-world rollback or resimulation of physics, navigation, animation,
  projectiles, or arbitrary scene state.
- Rewind-based hit validation or projectile lag compensation.
- Peer-authoritative gameplay or client authority over attributes, tags,
  effects, target resolution, damage, or random outcomes.
- Host migration or peer-to-peer consensus.
- Matchmaking, lobby, NAT traversal, account authentication, or an
  anti-cheat service.
- Compatibility with a non-Godot server implementing Godot's high-level
  multiplayer protocol.

These are non-goals, not gaps in protocol 2 — reconciliation
in this addon is explicitly scoped to gameplay-ability-component state only
(see `determinism.md` and design.md's "Component-Local Reconciliation").

## Known discrepancies

- **`ga_limits.h` has grown beyond the seed table in the shared implementation
  contract (`GA_CONTRACT.md` section 5).** Every constant the contract's
  table names matches the code exactly (verified individually while writing
  this document: `GA_API_VERSION_*`, `GA_PROTOCOL_VERSION`,
  `GA_MANIFEST_ALGORITHM`, `FIXED_SCALE`, `DEFAULT/MIN/MAX_TICK_RATE`,
  `MAX_IDENTIFIER_BYTES/SEGMENTS`, `MAX_QUERY_DEPTH/OPERANDS`,
  `MAX_TAG_SOURCES`, `MAX_ATTRIBUTES`, `MAX_MODIFIERS`,
  `MAX_ACTIVE_EFFECTS`, `MAX_ABILITY_GRANTS`, `MAX_ACTIVE_EXECUTIONS`,
  `MAX_TARGETS_PER_COMMAND`, `MAX_SET_BY_CALLER`, `MAX_EVENT_RECURSION`,
  `MAX_PERIODIC_CATCHUP`, `MAX_PENDING_PREDICTIONS`,
  `MAX_PREDICTION_JOURNAL_OPS`, `MAX_COMMAND_PACKET_BYTES`,
  `MAX_EVENT_BATCH_BYTES`, `MAX_STRING_BYTES`,
  `MAX_DIAGNOSTIC_BYTES`, `MAX_COMMANDS_PER_SECOND`,
  `MAX_RESYNCS_PER_MINUTE` — no numeric contradiction found anywhere). But
  `ga_limits.h` also defines seven constants the contract's table never
  listed: `MAX_EFFECT_MODIFIERS`, `MAX_GRANTED_TAGS`, `MAX_STACK_COUNT`,
  `MAX_PREDICTION_AGE_TICKS`, `MAX_HANDSHAKE_BYTES`, `MAX_EVENTS_PER_BATCH`,
  and `MAX_COLLECTION_COUNT`. This is additive, not conflicting — the
  contract's table was written before the protocol/effect work that needed
  these — and design.md's own "Open Questions" explicitly deferred "the
  exact canonical packet codec, initial per-packet byte limits, and
  supported tick-rate range" to implementation. Recorded here rather than
  silently reconciled, per this task's instruction to flag rather than paper
  over.
- **`MAX_SNAPSHOT_BYTES` is a deliberate numeric evolution from the
  contract's seed table.** The contract lists 32,768; protocol 2 defines
  131,072. This is a
  deliberate, spec-tracked change (`tasks.md` 11.9, `add-gameplay-ability-foundation-2026-07-24`),
  not drift: the performance-budget work (task 11.6) measured that a legal,
  fully-populated component (tags at `MAX_TAG_SOURCES`, attributes at
  `MAX_ATTRIBUTES`/`MAX_MODIFIERS`, effects at `MAX_ACTIVE_EFFECTS`, plus
  ability grants at `MAX_ABILITY_GRANTS` and active executions at
  `MAX_ACTIVE_EXECUTIONS`) encodes to 39,281 bytes — already over the
  original 32,768-byte limit even before abilities were folded in
  (34,079 bytes for tags+attributes+effects alone). It was first raised for
  the legal component maximum and is now 131,072 so bounded Ability Task and
  targeting-session sections fit the same restore envelope. Protocol 2 is
  the explicit incompatibility boundary.
- **Resolved since this document was first written: the handshake DTOs now
  populate `identifier_dictionary_fingerprint`/`content_manifest_fingerprint`
  from a live registry at runtime.** `GameplayAbilityComponent::configure()`
  builds a real `ga::ManifestBuilder` and `GameplayAbilityNetworkBridge`
  reads it into every outgoing handshake and snapshot envelope — see
  "Handshake fingerprints are live" above. The residual gap is narrower than
  before: `identifier_dictionary_fingerprint` still reuses
  `content_manifest_fingerprint`'s value instead of a second, identifier-only
  hash (diagnostic precision only — compatibility is unaffected).
- **Resolved since this document was first written (task 7.19): the
  manifest's tick-rate contribution is no longer hardcoded.**
  `GameplayAbilityComponent::configure()` now builds its `ManifestBuilder`
  with this component's own `tick_rate` property (a pre-configuration
  property immutable once configured, exactly like `role`/`entity_id`) —
  see "Handshake fingerprints are live" above. This was previously the one
  remaining place `ga_manifest.h`'s documented tick-rate contribution was
  not exercised end-to-end through the Godot layer;
  `manifest_tick_rate_difference_changes_fingerprint`'s guarantee is now
  proven at the Godot layer too, by
  `tests/gameplay_abilities/integration/test_component_runtime.gd`'s
  `_test_tick_rate_changes_manifest_fingerprint_and_handshake`.

No other discrepancy between the delta specs and the current implementation
was found while writing this document.
