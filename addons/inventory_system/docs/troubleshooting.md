# Troubleshooting

Common failure modes, what they mean, and where to look — grounded in this
addon's actual `StatusCode`/`DiagnosticId` values
(`native/core/inv_status.h`) and façade behavior, not generic advice.

## "InventoryCatalog native class is not registered"

The GDExtension did not load for the current platform/build-type. Check:

- `addons/inventory_system/inventory_system.gdextension` declares an entry
  for your exact `(platform, build-type[, arch])`.
- The declared artifact file actually exists under `addons/inventory_system/bin/`
  (see [`distribution.md`](distribution.md)'s "Building the artifact").
- `addons/inventory_system/release_manifest.json`'s matching target entry —
  if its `support_state` is `"planned"`, the artifact was never built for
  that target at all.

`tests/inventory_system/smoke/inv_smoke_main.tscn`
(`tools/godot.sh run tests/inventory_system/smoke/inv_smoke_main.tscn`) is
the fastest way to confirm this in isolation; it fails loudly with the exact
missing class/method/signal name rather than a generic engine error.

## `seal()` / `register_*()` fails with `STATUS_CATALOG_SEALED` or `STATUS_CATALOG_NOT_SEALED`

Registration (`register_item`, `register_container`, `register_profile`,
`register_trait_schema`, `register_catalog_resource`,
`register_integration_mapping`) is only valid **before** `seal()`; every
command/construction method (`create_inventory`, command submission,
snapshot/delta encode) is only valid **after**. `catalog.is_sealed()` tells
you which side you are on. This is deliberate, not a bug: a catalog is
immutable once sealed (`authoring.md`), and mutating the ORIGINAL authoring
`Resource` objects after seal is a documented no-op against the sealed
catalog too (task 7.2 mutation isolation — see `api.md`'s
`InventoryCatalog` section and
`tests/inventory_system/contract/inv_contract_main.gd`'s
`_test_mutation_isolation`).

## A command returns `accepted: false` — reading the rejection

Every command result Dictionary carries `status: Dictionary{code,
diagnostic, detail, ok}` even when accepted (`api.md`'s "Command result
Dictionary shape" table). On rejection, `status.code` is one of
`StatusCode`'s command-path values
(`REVISION_MISMATCH`, `DUPLICATE_COMMAND`, `PERMISSION_DENIED`,
`ROLE_VIOLATION`, `INVARIANT_VIOLATION`, `COMMAND_REJECTED`,
`SNAPSHOT_REQUIRED`) and `status.diagnostic` narrows the reason further —
the ones you will see most from constraint rejections are `FILTER_TRAIT_MISMATCH`
(118), `SLOT_UNKNOWN` (119), `LIST_ORDINAL_INVALID` (120),
`PLACEMENT_OVERLAP` (112), `PLACEMENT_OUT_OF_BOUNDS` (113),
`NESTING_DEPTH_EXCEEDED` (115), `OWNERSHIP_DUPLICATE` (111), and
`REVISION_STALE` (110). A rejected command changes NOTHING — no bytes,
hashes, revisions, idempotency state, references, or emitted-event count for
any touched aggregate (tasks.md 5.10); if you observe otherwise, that is a
real bug, not documented behavior.

**`REVISION_MISMATCH` looks unreachable through the typed command methods**
(`move_item`, `insert_item`, ...) — that is expected, not a bug. Every typed
method on `InventoryAuthority` always recomputes its own expected revision
from the façade's CURRENT runtime state before submitting (there is no
stale-revision override in this slice); the only façade entry point that can
observe a real `REVISION_MISMATCH` is `submit_command_bytes()` with a
caller-supplied (possibly stale) `CommandEnvelope`. See `api.md`'s
`submit_command_bytes()` entry and
`tests/inventory_system/contract/inv_contract_main.gd`'s
`_test_remote_command_bytes()` for a worked example.

**Mutable components do not merge accidentally.**

`set_item_component()` and `remove_item_component()` are ordinary
transactional authority commands: they validate identifiers and payload
bounds, participate in permission/revision/idempotency checks, advance the
inventory revision on acceptance, and emit `COMPONENT_SET` (14) or
`COMPONENT_REMOVED` (15) events with matching delta ops. Split and transfer
operations preserve the complete component state. Two otherwise-compatible
stacks merge only when their sorted component identifiers and payload bytes
match exactly; a mismatch rejects atomically with
`INVALID_ARGUMENT`/`STACK_COMPONENT_MISMATCH` (168). If a component mutation
is rejected, inspect the returned `status` and verify that the snapshot bytes
and revision are unchanged.

Items that own provided containers never split or coalesce. Direct split or
merge rejects with `INVALID_ARGUMENT`/
`STACK_PROVIDED_CONTAINER_UNSUPPORTED` (169); quick and targeted transfers
skip stack coalescing and move the whole item subtree only when a complete
destination placement exists. This prevents nested contents from being
silently destroyed by an otherwise legal quantity merge.

## A replica needs resync / `apply_delta_bytes()` returns `applied: false`

For the canonical `InventoryReplicaNode`, `applied: false` with `ok: true` is
a harmless no-op when a permission-filtered server message has no entry for
that replica's own inventory. `InventoryAuthority.delta_ready` and
`last_delta_batch_bytes()` are server-local raw multi-inventory integration
bytes: never broadcast them. A canonical gap or impossible transition
requires a fresh owner-only result from the gateway after completed hello and
the exact owner grant; never patch a gapped canonical replica with raw
authority deltas.

For `InventoryObserverReplicaNode`, a delta must match the immutable exact
recipient/inventory/visibility tuple and predecessor sequence. A duplicate or
stale observer delta is an idempotent `{ok: true, applied: false}` no-op. A
gap, wrong generation, malformed successor, or packet from another stream
leaves the last safe value untouched, sets `needs_resync()`, and emits
`resync_needed` once. After `configure_stream()` but before the first baseline,
`resync_request_bytes()` is a valid bootstrap request with generation `0` and
last sequence `0`; once initialized it carries both current positive values.
After completed hello, fetch a fresh `gateway.resync_bytes(peer, session,
connection_epoch, request_bytes, now_tick)` response under the stored observer
grant and call `apply_snapshot_bytes()` again. Never route observer bytes
through `InventoryReplicaNode` or canonical restore. See
`integration.md`'s observer flow for the exact tuple and authentication
boundary.

## Discovery Search/Scan is rejected or `discovery_needs_resync()` is true

Do not reuse a token from an older view or another actor. Tokens are scoped to
the authenticated recipient and rotate when canonical mutation changes the
safe projection. `DISCOVERY_REVISION_STALE`, `DISCOVERY_TOKEN_INVALID`, or
`DISCOVERY_TARGET_STALE` means clear the local pending intent and fetch a new
`discovery_view_bytes()`; a replica revision gap likewise requires a full
view, not another delta. `DISCOVERY_BUSY` means this actor already owns its
one active task. `DISCOVERY_QUERY_REDACTED` and `DISCOVERY_NOT_INDEXED` are
privacy decisions, not missing data: Search must finish before layout/count
or entry scanning becomes available. See
[`discovery.md`](discovery.md#troubleshooting) for every discovery diagnostic.

## `apply_persistence_record()` fails, or loads the wrong thing

- `STATUS_ALREADY_EXISTS` (`OWNERSHIP_DUPLICATE` diagnostic) — the record's
  inventory id is already live. The default load is collision-safe and leaves
  that runtime untouched; use `apply_persistence_record(bytes, true)` only
  when the caller is deliberately establishing a replacement generation. On
  successful replacement, prior accepted command results that touched this
  inventory are removed from the bounded idempotency journal; a reused command
  id is therefore evaluated against the restored state, not reported as a
  stale replay. Cached commands concerning only other inventories are retained.
- `STATUS_LIMIT_EXCEEDED` (`OVERFLOW_DETECTED` diagnostic) — the encoded
  inventory id cannot be represented by Godot's signed `int`, or the authority
  has exhausted that script-safe id space.
- `STATUS_SCHEMA_MISMATCH` (`PERSISTENCE_SCHEMA_VERSION_UNSUPPORTED`
  diagnostic) — the record's persistence schema version predates or
  postdates what this build supports/can reach via a migration chain; you
  need an explicit migration function
  (`docs/inventory/compatibility.md`'s migration policy), not a silent
  best-effort decode.
- `STATUS_MANIFEST_MISMATCH` (`MANIFEST_FINGERPRINT_DIFFERS`,
  `SESSION_MANIFEST_ALGORITHM_MISMATCH`, or
  `PERSISTENCE_RECORD_IDENTITY_MISMATCH` diagnostic) — the record's manifest
  fingerprint/algorithm does not match this catalog's `manifest_fingerprint()`,
  or the decoded snapshot's own identity disagrees with the enclosing
  record's. All fail-closed by design: a persisted inventory from a
  DIFFERENT catalog (different item/container/profile definitions), or a
  record whose own fields disagree internally, is never silently
  reinterpreted against the wrong definitions.
- A tampered/corrupted record's hash check or the decoder's own bounded
  reads reject before touching the target authority's runtime state at all
  — `apply_persistence_record()` never partially loads (see
  `native/tests/inv_test_persistence.cpp`'s
  `load_inventory_rejects_*`/`make_persistence_record_and_load_inventory_round_trip_atomically`
  tests for the exact guarantees).

## `unload_inventory()` is rejected or a mirror remains visible

`unload_inventory(id)` requires a positive, currently live authority-owned
inventory id. It returns `{ok: false, status: ...}` for invalid/unknown ids,
and returns `STATUS_COMMAND_REJECTED` with the
`AUTHORITY_LIFECYCLE_BUSY` diagnostic when called synchronously from any
authority signal callback. That guard is deliberate: signal arguments may
still reference the old runtime, so lifecycle mutation waits until the
callback returns. A successful call clears only the selected inventory's
reservations, discovery state, idempotency entries, and touched last-delta
cache before erasing the runtime, then emits `inventory_unloaded`.

`InventoryReplicaNode` instances are independently owned and are not reset by
the authority. Have the game/network bridge listen for `inventory_unloaded`
and dispose the matching mirror (or forward an equivalent lifecycle message)
itself. For an explicit same-id persistence replacement, listen for
`inventory_generation_changing(inventory_id)`. It fires before the new same-id
runtime is made visible; invalidate the old-generation mirror, observer stream,
replay receipt, and cached egress at that edge before forwarding the new
baseline. A bound gateway also discards the affected grants and replay state.

## Snapshot content looks different than expected for a non-owner

`InventoryAuthority.snapshot(inventory_id, visibility)` is a local/debug value
projection. Its non-owner Resource is inspectable but is not canonical restore
input and must not be transmitted as an owner snapshot. The canonical
`snapshot_envelope_bytes(...)` transport is owner-only and returns a role
violation for non-owner visibility. For an untrusted peer, use the dedicated
`observer_snapshot_envelope_bytes(...)` plus `InventoryObserverReplicaNode`.

Observer `VISIBILITY_OBSERVER` keeps policy-authorized public rows and uses
opaque aggregate shells for redacted regions. `VISIBILITY_REDACTED` exposes
only policy-permitted aggregate shells/counts: hidden item identifiers,
definitions, quantities, locations, components, provided-container links,
references, and allocator state never cross the observer boundary. Recipient
handles are local opaque values and cannot be interpreted as canonical ids.

## `InventoryNetworkGateway` rejects a session or command

The gateway is a server/game-owned, transport-neutral façade, not an RPC
endpoint. It owns no `MultiplayerPeer`, socket, thread, or timer. The game
transport must pass the trusted peer obtained from its connection context
(`get_remote_sender_id()` in a Godot RPC handler); never copy peer, actor, or
visibility from packet bytes. `InventoryAuthority` command bytes are raw
protocol bytes, not RPC messages.

The gateway must point at an `InventoryAuthority` with
`ROLE_SERVER_AUTHORITY`, a positive immutable authority epoch, and a valid
tick rate. `ROLE_VIOLATION`/`AUTHORITY_CALLBACK_FORBIDDEN` means the node is
not attached to a server-role authority. `VALUE_OUT_OF_RANGE` means one of
the epoch, tick, peer/session/actor, connection epoch, allowlist, or tick
arguments is zero/negative/out of bound. `SESSION_UNKNOWN` (171) means the
peer/session binding does not exist; `CONNECTION_EPOCH_MISMATCH` (172),
`AUTHORITY_EPOCH_MISMATCH` (173), and `ACTOR_MISMATCH` (174) mean the trusted
context is for another connection/authority/actor. `SESSION_HELLO_REQUIRED`
(191) means exact `SessionHello` admission has not succeeded for this
session/epoch tuple.

Fresh logical session ids must strictly increase within one authority epoch;
`SESSION_RETIRED` (or an equivalent stale-session diagnostic) means a new
logical session reused a lower/equal id. Reconnect keeps the same session id
and actor/authority epoch but requires a strictly higher connection epoch. It
may migrate to a different authenticated peer, moving grants, replay/sequence
state, and both rate buckets; the old-peer/old-epoch context is then rejected.
A higher authority epoch starts a fresh id domain only after all live sessions
are gone; changing that domain while live fails closed.

Command admission is default-deny. The packet's
`CommandEnvelope.header.command_id` is only a client-local sequence and
`header.actor` is only an exact echo check. A `COMMAND_NOT_ALLOWLISTED` (175)
diagnostic means the class mask did not grant the command. An
`AUTHORITY_ONLY_COMMAND` (176) diagnostic means the command is one of the
six hard authority-only classes — `INSERT_ITEM`, `REMOVE_ITEM`, `DROP_ITEM`,
`SETTLE_INVENTORY`, `SET_ITEM_COMPONENT`, or `REMOVE_ITEM_COMPONENT` — and
remote gateway ingress rejected it. Their mask bits do not make them
remote-admissible; a trusted server/game path must invoke those authority
operations directly after its own policy check. Other commands also need an
exact command-inventory grant; `INVENTORY_ACCESS_DENIED` (181) means that
grant is missing. A nonzero class mask does not substitute for the grant.

Admission order is deliberate: rate/bounds and session/hello checks, decode
and identity/class/grant checks, touched-inventory revision lookup, then the
mandatory game-owned world-policy callback, and only then allocator/executor.
`GATEWAY_CALLBACK_MISSING` (179) is a missing callback, not permission to
proceed. `GATEWAY_TOUCHED_SET_INVALID` (180) indicates the callback or
executor reported an invalid touched set. A policy rejection is returned as
the callback's status. Malformed and oversize command bytes consume the
command rate bucket before decode. SessionHello attempts share the
authenticated command-ingress bucket and consume it before hello readiness,
size/decode, or compatibility; malformed and oversized hello or command
bytes consume that same bucket.

If a world-policy callback tries to submit typed/raw commands, unload or
persistence replacement, quantity reservations, discovery mutations, or any
other `InventoryAuthority` mutation, treat it as a callback contract failure:
the callback is trusted server code and must be pure during evaluation. The
gateway blocks recursive gateway entry, but it cannot generally undo arbitrary
authority or external side effects performed by callback code; move those
actions out of policy evaluation and perform them in an explicit server step.

The engine-free/custom `CommandExecutor` callback is synchronous and
immediate. It must not enqueue work or perform any side effects when it
returns a `queued` result; the gateway rejects queued outcomes because they
cannot produce one authoritative reply in the current admission call.

## Gateway replay, epochs, grants, and rate limits

Replay keys use the authenticated session plus the client-local command id
and the complete command bytes. An exact duplicate of an accepted command
returns a normalized receipt with `DUPLICATE_RESULT_REPLAY` (136),
`replayed=true`, no events, and no delta/side-effect bytes; the executor is
not run again. `COMMAND_SEQUENCE_CONFLICT` (178) means the same id carried
different bytes; `COMMAND_SEQUENCE_STALE` (177) means the entry was evicted or
is below the retained sequence; and `COMMAND_REPLAY_IN_FLIGHT` (184) means a
re-entrant duplicate was rejected. Revoking an inventory grant blocks replay
immediately; replay state cannot restore a grant. The executor sees
server-canonical actor and command id, not the packet echo/local sequence.

`COMMAND_RATE_EXCEEDED` (187) and `RESYNC_RATE_EXCEEDED` (188) are separate
token buckets. Defaults are 32 commands/second and 16 resyncs/minute at a
60-tick rate. Bounds are 1024 sessions, 256 command grants/session, 64
engine-free observer grants/session, 256 replay entries/session, and 4 MiB
retained replay bytes globally (including in-flight reservations), plus a 1 MiB
observer view plus 512 bytes envelope overhead, 128-byte observer resync
requests, 32 streams/recipient, 512 streams globally, and 65,536 generation
keys. The Godot façade additionally caps the combined owner plus
observer/redacted replication map at `MAX_REPLICATION_GRANTS_PER_SESSION =
256`; this does not raise the engine-free observer cap. A bound failure is
fail-closed; do not retry with a larger transport payload.

A same-session reconnect with a strictly newer connection epoch requires the
exact hello again but preserves grants, replay entries, sequence floors, and
both rate-bucket budgets. It may use a different authenticated peer; the
gateway moves the logical session and rejects the old-peer/old-epoch context.
A lower/rollback connection epoch is rejected with
`CONNECTION_EPOCH_MISMATCH` (172). Do not treat reconnect as a way to reset
rate limits.

Command grants and replication grants are independent. `OBSERVER_GRANT_MISSING`
(182) means no stored observer/redacted replication scope exists; owner
replication is also not implied by a command grant. `RESYNC_IDENTITY_MISMATCH`
(183) means the trusted tuple or packet's recipient/inventory identity does
not match the session/stream. Observer visibility is looked up from the
stored grant because the resync packet carries no visibility authority.
`generation=0`/`sequence=0` is the valid bootstrap scope; later generation or
predecessor mismatches require a fresh baseline. Direct
`snapshot_result()`/`snapshot_bytes()`, `delta_result()`/`delta_bytes()`, and
`resync_result()`/`resync_bytes()` are trusted server egress only, never remote
RPC entry points, and require completed exact hello (`session_ready(session)`)
in addition to the replication grant/tuple. If a push or resync is rejected
before hello admission, admit the exact SessionHello for the current epochs
first. On `inventory_unloaded` or
`inventory_generation_changing(inventory_id)`, invalidate matching
replica/observer mirrors and cached egress before accepting new-generation
bytes.

Gateway command acknowledgements are conservative: one-shot transaction
events, canonical deltas, and dropped side-effect payloads are never exposed.
Detailed IDs and revision arrays are retained only when the session has
`VISIBILITY_OWNER` replication grants for every touched inventory;
otherwise inspect the minimal status/admission/replay receipt and its
`owner_result_scope=false` marker. Command permission or an observer/redacted
grant alone does not widen an acknowledgement.

## A game-owned permission check never runs

`InventoryAuthority` hard-codes an always-allow `AllowAllPermissionProvider`
for direct local calls in this slice — there is no Godot-bound
`inv::PermissionProvider` replacement. For remote command bytes, install the
gateway's mandatory `world_policy` Callable and have it check game ownership,
world, and gameplay rules after the gateway has authenticated the tuple and
read current revisions. A missing callback fails closed. Direct authority
calls still require the game bridge to authenticate and authorize before
invoking them. See `docs/README.md`'s "What this slice implements (and what
it does not)" section.

## `OFFLINE_AUTHORITY` and `SERVER_AUTHORITY` behave identically

That is expected in this slice: `role` is a labeling-only property (see
`inventory_authority.h`'s own class comment) — both roles are full canonical
authority over their owned runtimes, with no functional difference yet. The
STRUCTURAL half of role safety that IS enforced is one-directional:
`InventoryReplicaNode` exposes no mutation method at all (verified by
`tests/inventory_system/smoke/inv_smoke_main.gd`'s `FORBIDDEN_REPLICA_METHODS`
list and `tests/inventory_system/server/inv_server_main.gd`'s equivalent
live-instance check) — a remote replica cannot invoke an authority-only
command, but nothing yet distinguishes an offline single-player authority
from a networked dedicated-server authority behaviorally.

## Export succeeds but the exported package won't run the addon

Run `tools/inv_export_smoke.sh <preset> [debug|release]` — it exports
headlessly and specifically confirms `libinventory_system.*` is present in
the exported package, failing loudly if it is not (rather than the export
step's own "success" being taken at face value). Exit code `3` means Godot
export templates are not installed locally (not a real failure) — install
them or run in CI, which does.

## Where to look next

- Full method/signal/enum reference: [`api.md`](api.md).
- Every test suite and what it proves: [`verification.md`](verification.md).
- Ownership/lifetime/authority/persistence/networking walkthrough:
  [`integration.md`](integration.md).
- Presentation-layer state precedence and controls: [`presentation.md`](presentation.md).
- Pre-1.0 compatibility/migration policy:
  [`../../../docs/inventory/compatibility.md`](../../../docs/inventory/compatibility.md).
