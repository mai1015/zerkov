# Compatibility (Façade View)

The canonical, authoritative compatibility policy lives in
[`docs/inventory/compatibility.md`](../../../docs/inventory/compatibility.md)
(version-decision table, session-compatibility axes, resource/feature
compatibility, persistence compatibility, golden-fixture policy, and the
pre-1.0 release gate) and
[`docs/inventory/contracts.md`](../../../docs/inventory/contracts.md)
(reserved names/namespaces, the 6 independent version axes and their V1
values, the status/diagnostic taxonomy, hard default limits). **This
document does not restate that policy** — it is the narrower, façade-level
view: how to READ each version axis from the Godot classes, and what the
façade actually does with them.

## The 6 independent version axes, and how to query each one

| Axis | V1 value | Query from `InventoryCatalog` |
|---:|---|---|
| Semantic API (`inventory.api`) | `0.4.0` | `api_version()` / `api_version_major()` / `_minor()` / `_patch()` |
| Wire protocol (`inventory.protocol`) | `1` | `protocol_version()` |
| Authoring resource schema (`inventory.resource_schema`) | `1` | `resource_schema_version()` |
| Native feature-module contract (`inventory.feature_module`) | `1` | `feature_module_version()` |
| Persistence record schema (`inventory.persistence_schema`) | `1` | `persistence_schema_version()` |
| Canonical manifest algorithm (`inventory.manifest`) | `"fnv1a64-canonical-v1"` | `manifest_algorithm()` |

These axes do not move in lockstep — a compatibility check must use the
relevant axis, never infer compatibility from `api_version()` alone. The
contract suite's `_test_version_queries()` parses
`addons/inventory_system/release_manifest.json` directly and asserts every
one of the getters above agrees with it, so the release manifest and these
getters can never silently drift apart without failing that suite.

Two more façade-relevant values, also queried from `InventoryCatalog`:

- `mass_unit()` — `"milligram"`. The canonical mass unit; see
  `docs/inventory/contracts.md`'s "floating-point mass is never
  authoritative" rule.
- `manifest_fingerprint()` — `0` before `seal()`, otherwise the `fnv1a64`
  fingerprint over every registered authority-affecting definition/module/
  limit for THIS specific catalog instance. Not a version axis itself, but
  the value two peers actually compare during session negotiation (below) to
  detect CONTENT drift within the same axis versions.

## Session negotiation: `session_hello_bytes()`

`InventoryAuthority.session_hello_bytes()` encodes a `protocol::SessionHello`
for the sealed catalog — the wire message a game's bridge exchanges with a
remote peer BEFORE any command or state exchange, covering the 6-item
session-compatibility checklist `docs/inventory/compatibility.md` documents
(protocol version, mass unit, required protocol feature bits, hard-limit
contract, canonical identifier dictionary, and the authority-affecting
content-manifest fingerprint). This façade slice encodes the message; it does
NOT itself decode a peer's reply or drive the accept/reject decision — that
comparison, and what a game does on mismatch (refuse the session; never fall
back to local definition order or best-effort decoding), is game-bridge code
built on top of the bytes. Call it once per new session, before the first
`snapshot_envelope_bytes()`/`apply_snapshot_bytes()` exchange described in
[`integration.md`](integration.md)'s network walkthrough.

Protocol feature bit `1 << 7` is `TARGETED_PROVIDER_TRANSFER`; bit `1 << 8`
is `MUTABLE_COMPONENT_COMMANDS`; bit `1 << 9` is `OBSERVER_REPLICATION`. A
peer that lacks either command bit cannot admit the corresponding command tags
(`17` for targeted-provider transfer, `18` / `19` for set/remove component).
A peer that lacks bit 9 cannot admit recipient-bound observer replication.
Negotiation fails closed before the payload can be interpreted as another
command kind or an observer packet.

## Recipient-safe observer compatibility

Observer packets remain under main wire protocol version `1`, but use an
explicitly separate domain: magic `inventory-observer-v1`, observer protocol
version `1`, and bounded observer snapshot/delta/resync codecs. The separate
magic is a fail-closed type boundary; an observer replacement view must never
be passed to the canonical `InventoryReplicaNode` or a canonical restore
path. SessionHello compatibility, including required feature bit `1 << 9`,
must succeed before the first observer byte is accepted.

The observer hard-limit contract is part of the negotiated manifest/digest:
the projected view is capped at `MAX_OBSERVER_VIEW_BYTES` (currently the
1 MiB snapshot bound), snapshot and full-replacement delta envelopes add at
most 512 bytes of framing, resync requests are capped at 128 bytes, each
recipient may hold at most 32 streams, and the authority retains at most 512
observer streams globally. Any bound or observer wire identity mismatch is a
session incompatibility, not a best-effort decode case.

Generation epochs are retained in a bounded per-recipient ledger across
stream teardown and re-registration. The ledger accepts at most
`MAX_OBSERVER_GENERATION_KEYS` (currently 65,536) distinct recipient keys; a
new key beyond that cap is rejected rather than evicting an older epoch.

Each stream is bound to the exact `(session_id, actor_id, inventory_id,
visibility, generation)` tuple. Baselines and deltas are full projected
replacement views with an independent recipient-visible sequence. A hidden-
only canonical change produces no bytes and does not advance that sequence.
Opaque container/item handles are recipient-local and are not canonical ids;
`REDACTED` views contain aggregate-only container shells rather than hidden
item rows. A generation or predecessor mismatch requires a fresh baseline;
the observer replica never attempts canonical recovery.

`ObserverResyncRequest` intentionally omits visibility; packet content never
grants or changes scope. The Task 4.6 gateway resolves visibility from the
authenticated configured `(recipient, inventory)` stream policy/cache,
including a configured `generation=0`/`last_applied_sequence=0` bootstrap when
no cached view exists.

`register_discovery_recipient()` and the authority observer methods are local
non-RPC lifecycle primitives. Registration does not authenticate a peer or
authorize access to an inventory. The Task 4.6/game gateway must authenticate
the transport principal and authorize the exact recipient, inventory, and
visibility policy before invoking or transmitting observer bytes.

## Authenticated gateway compatibility

API `0.4.0` adds `InventoryNetworkGateway` while keeping wire protocol `1`.
It is a server/game-owned, transport-neutral façade: it creates no
`MultiplayerPeer`, socket, RPC endpoint, worker, or timer. The game transport
must obtain the trusted peer from its connection context (`get_remote_sender_id()`
in a Godot RPC handler) and pass that peer/session/connection-epoch tuple to
the gateway. `InventoryAuthority` command bytes are raw protocol bytes, not
RPC messages, and packet peer/actor/visibility fields are never trusted.

The configured positive authority epoch, per-session actor, and positive
connection epoch are exact identity domains. A session must be admitted with
the exact `SessionHello` before command, push snapshot, push delta, or resync
bytes are accepted. Fresh logical session ids must strictly increase within
one authority epoch. A reconnect keeps the same logical session id and exact
actor/authority epoch while strictly advancing `connection_epoch`; it may
arrive on a different authenticated peer, moving grants, replay/sequence
state, and both rate-bucket budgets while rejecting stale old-peer/old-epoch
traffic. A higher authority epoch starts a fresh id domain only after all
live sessions are gone; rollback or live rotation fails closed. The command
allowlist is default-deny; command admission additionally requires an exact
command-inventory grant. The gateway always hard-rejects the six
authority-only classes (their mask bits do not make them remote-admissible):
`INSERT_ITEM`, `REMOVE_ITEM`, `DROP_ITEM`, `SETTLE_INVENTORY`,
`SET_ITEM_COMPONENT`, and `REMOVE_ITEM_COMPONENT`. A trusted server/game
path must invoke those authority operations directly after its own policy
check.

`CommandEnvelope.header.command_id` is a client-local sequence used for an
exact-byte replay key and `header.actor` is an exact echo. Both are replaced
by server canonical identity before authority execution. Exact duplicate
accepted bytes return a normalized `DUPLICATE_RESULT_REPLAY` receipt with
`replayed=true`, no events, and no delta/side-effect bytes, without executing
again; different bytes conflict, evicted/lower entries are stale, revocation
blocks replay, and in-flight or re-entrant replay fails closed. The order is fixed: admission/rate and bounds,
decode/identity/class/grants, touched-inventory revision, then the mandatory
game-owned world-policy callback, then allocator/executor. Missing policy is
deny. SessionHello attempts share the authenticated command-ingress bucket and
consume it before hello readiness, size/decode, or compatibility; malformed
and oversized hello or command bytes consume that same budget. Resync uses a
separate bucket.

Remote command acknowledgements are conservative: one-shot transaction
events, canonical delta bytes, and dropped side-effect payloads are never
exposed. Detailed transaction IDs and revision arrays are retained only when
the session has `VISIBILITY_OWNER` replication grants for every touched
inventory; otherwise the gateway returns bounded status/admission/replay
metadata with `owner_result_scope=false`. Command permission or an
observer/redacted grant alone cannot widen the acknowledgement.

The installed world-policy `Callable` is trusted server code and must be pure
with respect to `InventoryAuthority` while it is evaluated. It must not submit
typed or raw commands, perform lifecycle operations (including unload or
persistence replacement), mutate quantity reservations, perform discovery
mutations, or make any other authority mutation, and it must not perform
external side effects. Gateway recursion is blocked, but arbitrary side
effects performed by trusted callback code cannot generally be rolled back.

The engine-free/custom `CommandExecutor` callback is synchronous and
immediate. It must not enqueue work or perform any side effects when it
returns a `queued` result; the gateway rejects queued outcomes because they
cannot produce one authoritative reply in the current admission call.

Command grants and replication grants are independent. Owner replication is
canonical owner egress; observer/redacted replication is a separate
recipient-safe full-replacement stream. Observer resync derives visibility
from the stored grant, not from the request; `generation=0`/`sequence=0` is
the valid bootstrap scope, while later generation/predecessor mismatches
require a fresh baseline. `snapshot_result()`/`snapshot_bytes()` and
`delta_result()`/`delta_bytes()` are trusted server egress methods only and
require completed exact hello (`session_ready(session)`) for the current
epochs; a replication grant cannot push state before hello admission. Owner
and observer `resync_result()`/`resync_bytes()` likewise require completed
hello plus the stored grant/tuple. Unload or explicit same-id persistence replacement
invalidates affected replay, stream, reservation, and last-delta state and
emits the authority replacement lifecycle notification for bridge mirrors.
Recipient-filtered OWNER `DeltaBatch` egress always sets `source_command_id`
to `0`; the authority-global id is retained only in the server-local raw
`delta_ready`/`last_delta_batch_bytes()` batch. This prevents it from
correlating other touched inventories or principals.

The negotiated/default bounds are 1024 sessions, 256 command grants and 64
engine-free observer grants per session, 256 replay entries per session, 4 MiB
retained replay bytes globally (including in-flight reservations), 32
commands/second, and 16 resync requests/minute at the default 60 ticks/second,
together with bounded observer view/stream/generation ledgers. The Godot
façade additionally caps the combined owner plus observer/redacted replication
map at `MAX_REPLICATION_GRANTS_PER_SESSION = 256`; this does not raise the
engine-free observer cap. A transport wrapper must not widen these limits or
treat a bound failure as a best-effort decode.

## Discovery compatibility

Staged discovery uses a separately negotiated discovery protocol version
(`1`) carried by `discovery_hello_bytes()` and every discovery intent/result/
view/delta envelope. The optional feature and its hard bounds contribute to
the catalog manifest only after a catalog opts in; catalogs with no discovery
policies retain their existing `SessionHello`, manifest, container/profile
records, and instant-open behavior byte-for-byte. V1 discovery deltas are
complete replacement views with explicit predecessor/successor inventory and
discovery revisions. See [`discovery.md`](discovery.md) for the wire and
resync contract.

## Golden fixture policy pointer

Repository-owned compatibility fixtures live under `tests/inventory/
fixtures/` (see `docs/inventory/compatibility.md`'s "Golden fixture policy"
for the immutability/versioning rules that govern them — existing golden
inputs, outcomes, revisions, canonical bytes, and hashes within a version
directory are immutable; a breaking change creates a NEW version directory
rather than rewriting old evidence). This façade slice's own test suites
(`native/tests/inv_test_golden_zerkov.cpp`,
`native/tests/inv_test_zerkov_format.cpp`) are the current consumers of that
fixture set; nothing under `native/godot/` reads or writes fixtures directly.

## Practical recipes: "how do I add a field?"

The general rule is [`docs/inventory/compatibility.md`](../../../docs/inventory/compatibility.md)'s
version-decision table; these are the concrete steps for the changes a game
or a contributor to this addon most often needs to make. See
[`examples/inventory/README.md`](../../../examples/inventory/README.md) for
a worked catalog to practice against.

**Add a new field to an authoring Resource (item/container/profile/...).**
1. Add the property + `_bind_methods()` entry in the matching
   `native/resources/*.h/.cpp` class, with an explicit default matching
   today's implicit behavior (so an existing `.tres` that doesn't set it is
   unaffected).
2. Read the new field wherever the definition is copied into the sealed
   catalog (`native/core/inv_catalog.cpp` / the matching `Definition` struct
   in `native/core/inv_definitions.h`) and wherever it participates in
   `manifest_fingerprint()`'s canonical encoding
   (`native/core/inv_catalog.cpp`'s `encode_canonical()` family) — a field
   that affects authority behavior but is left out of canonical encoding
   would let two definitionally-different catalogs fingerprint identically,
   which `docs/inventory/contracts.md`'s manifest guarantee forbids.
3. Bump `resource_schema_version()` in `release_manifest.json` +
   `native/core/inv_version.h` only if the field changes how an EXISTING
   `.tres` without it must now be interpreted; a pure opt-in addition with a
   behavior-preserving default is schema-compatible (API minor bump only —
   see "What counts as a breaking façade change" below).
4. Add native unit-test coverage plus a headless Godot check
   (`tests/inventory_system/contract/inv_contract_main.gd`'s catalog-fixture
   section is the reference pattern), and update `authoring.md`'s field
   table.

**Add a new trait or feature module.** Traits are schema-only (no dedicated
version bump needed — `register_trait_schema()`); a genuinely new FEATURE
MODULE (a new `inventory.feature.*` identifier with its own runtime
behavior) is closer to a minor addition than a field change: register it in
`native/core/inv_builtin_features.h`/`.cpp` (or your own game-side native
extension) following an existing module's dependency-declaration/phase-order
shape, add native tests for its own constraint-ordering interaction with the
existing modules (tasks.md 5.8's canonical feature order), and document it
in `authoring.md`.

**Bump the persistence schema and migrate old records.** Increment
`persistence_schema_version()` in `release_manifest.json` +
`native/core/inv_version.h`, then register an explicit
`inv::protocol::MigrationChain::register_migration(from_version, fn)` step
(`native/protocol/inv_persistence.h`) — `MigrationFn` is a plain
`Status(PersistenceRecord &)` transform. `migrate_record()` walks a
CONTIGUOUS chain of registered steps from a record's current version to a
target version and fails closed
(`PERSISTENCE_SCHEMA_VERSION_UNSUPPORTED`/`PERSISTENCE_MIGRATION_GAP`
diagnostics — see [`troubleshooting.md`](troubleshooting.md)) if any step in
the path is missing; there is no implicit/best-effort decode across a schema
gap. Add a migration-chain test following
`native/tests/inv_test_persistence.cpp`'s `migration_chain_*` tests as the
reference pattern, and never rewrite an existing golden persistence fixture
in place — add a new version directory instead (`docs/inventory/
compatibility.md`'s "Golden fixture policy").

**Add a new façade method/signal/enum constant.** Additive-only, as long as
no EXISTING method's signature/return shape or Resource field's
default/meaning changes (see the next section) — API minor bump, document it
in `api.md`, and add contract-suite coverage
(`tests/inventory_system/contract/inv_contract_main.gd`).

## What counts as a breaking façade change

Every class, method, signal, and enum this addon exposes through
`native/godot/` is pre-1.0 (see [`api.md`](api.md)'s own pre-1.0 banner).
`docs/inventory/compatibility.md`'s version-decision table already covers the
general rule ("backward-compatible public façade addition: increment API
minor; breaking public façade change: increment API minor while pre-1.0;
publish source migration notes"); the façade-specific corollary is: adding a
new bound method/signal/enum constant to `InventoryCatalog`/
`InventoryAuthority`/`InventoryReplicaNode`/`InventorySnapshotResource`/any
authoring `Resource` class is additive (API minor bump only) as long as it
does not change any EXISTING method's signature, return shape, or a Resource
field's default/meaning. The `InventoryContainerConstraints.ACCESS_*`
bitfield binding this task added is exactly that kind of additive change: it
makes 4 already-documented integer VALUES referenceable by name — it does
not change `access_mask`'s type, default, or wire encoding in any way.

The `InventoryAuthority.unload_inventory()` method,
`inventory_unloaded(inventory_id)` signal, and explicit same-id replacement
`inventory_generation_changing(inventory_id)` signal are likewise additive
API-surface entries in `0.4.0`; the replacement signal fires before the new
same-id runtime is made visible, allowing local bridges and the bound gateway
to invalidate old mirrors, grants, replay state, and cached egress. They do
not add an automatic replica-reset wire operation.
