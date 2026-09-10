# Public API Reference

Every Godot-facing class this addon exposes: `InventoryCatalog`,
`InventoryAuthority`, `InventoryNetworkGateway`, `InventoryReplicaNode`,
`InventoryObserverReplicaNode`, `InventorySnapshotResource`, and
the 9 authoring `Resource` classes under `native/resources/`. Sourced
directly from each class's `_bind_methods()`/`ADD_SIGNAL`/`ADD_PROPERTY`
calls in `native/godot/*.cpp` and `native/resources/*.cpp` — not inferred
from the delta specs. Where a signature could not be verified against
source, it is not included.

## Pre-1.0 status — read this before depending on anything below

Per `addons/inventory_system/release_manifest.json`
(`api_version: "0.4.0"`, `protocol_version: 1`, `resource_schema_version: 1`):
**every class, enum, method, signal, and resource field in this document is
pre-1.0.** See [`compatibility.md`](compatibility.md) and
`docs/inventory/compatibility.md` for the version-decision table that governs
what counts as a breaking change while pre-1.0.

Per design.md's "Godot façade and authoring": **games integrate through
`InventoryCatalog`, `InventoryAuthority`, `InventoryNetworkGateway`,
`InventoryReplicaNode`, `InventorySnapshotResource`, the authoring `Resource` classes, and the value
Dictionaries/PackedByteArrays they exchange — never against the `inv::`/
`inv::protocol::` C++ namespaces**, which have no ClassDB registration and
are not reachable from GDScript or C# at all.

## Staged discovery API

The optional discovery surface adds `InventoryDiscoveryPolicy`, immutable
entry/container/task/result/snapshot/delta Resources, recipient lifecycle and
Search/Scan/Cancel/advance/view/delta methods on `InventoryAuthority`, and
view/delta reconciliation on `InventoryReplicaNode`. It uses an independent
discovery revision and recipient-bound opaque tokens; there is no client
completion method. The complete method signatures, Resource getters, protocol
flow, redaction rules, and security boundary are in
[`discovery.md`](discovery.md).

## Recipient-safe observer replication

Observer replication is a separate, recipient-bound value protocol. It is not
`InventoryReplicaNode` with a visibility flag: the observer envelope uses the
literal magic `inventory-observer-v1` and observer protocol version `1`, and
cannot be decoded by the canonical `SnapshotEnvelope`/`DeltaBatch` path or
restored as canonical state. The game bridge must exchange and validate
`session_hello_bytes()` before sending observer packets; the negotiated
`OBSERVER_REPLICATION` feature bit is `1 << 9`, and a peer that does not
advertise it must fail compatibility before any observer bytes are accepted.

The authority methods below are local, non-RPC primitives. Registering a
`(session_id, actor_id)` recipient is lifecycle state only, not authentication
or authorization. Task 4.6/game gateway code must authenticate the peer and
authorize the exact recipient, inventory, and visibility scope before invoking
these methods or transmitting their output. Never expose these methods as an
unvalidated remote RPC.

## Result, status, and diagnostic Dictionary shapes

These shapes recur across almost every method below, so they are documented
once here (`native/godot/inventory_godot_util.h`).

**`status` Dictionary** (`inv::Status` → Dictionary; carried by every command
result and every derived-query result):

```
{ code: int, diagnostic: int, detail: int64, ok: bool }
```

`code` mirrors `inv::StatusCode` (see `InventoryCatalog.StatusCode` below —
every numeric value is identical whether it arrives via this field or via
`InventoryCatalog`'s own bound enum). `diagnostic` mirrors `inv::DiagnosticId`
(`native/core/inv_status.h`) — deliberately **not** bound to ClassDB (matches
`gameplay_abilities`' own `ga::DiagnosticId` precedent), so read it as a plain
int and cross-reference that header, or `docs/inventory/contracts.md`'s
"Status and diagnostic taxonomy" table, when a specific diagnostic matters.

**Catalog diagnostic Dictionary** (every `InventoryCatalog` registration/
validation finding):

```
{ status_code: int, diagnostic: int, detail: int64, identifier: String, source: String }
```

`status_code` is the same `inv::StatusCode` numbering as `status.code` above
(named `status_code` here for historical/positional reasons — the value
space is identical). `source` is a stable, bounded label: the resource's own
`get_path()` if saved, else `"<anonymous KindName>"`.

**Command result Dictionary** (every `InventoryAuthority` typed-command
method's return value):

```
{
  accepted: bool, replayed: bool, queued: bool, status: Dictionary,
  command_id: int64,
  revisions: Array[Dictionary{inventory: int64, predecessor: int64, successor: int64}],
  events: Array[Dictionary{kind: int, item: int64, secondary_item: int64,
      source_container: int64, destination_container: int64, reference: int64}],
  new_item_id: int64, new_reference_id: int64, dropped_external_owner: int64,
  dropped_items: Array[Dictionary{item_definition_identifier: String,
      quantity: int64, mutable_components: Array[Dictionary{component_identifier: String, payload: PackedByteArray}],
      external_owner: int64}],
  transferred_quantity: int64, remaining_quantity: int64,
  conflicting_inventory: int64, authoritative_revision: int64,
}
```

Unused fields keep their zero/empty default rather than being omitted, so
every command's result Dictionary shares one stable shape (verified by the
contract suite's `expect_ok` helper). `revisions` has one entry per inventory
the command touched (even on rejection, so `predecessor == successor` is
directly assertable), in ascending inventory-id order. `conflicting_inventory`/
`authoritative_revision` are populated only when `status.code` is
`StatusCode.STATUS_REVISION_MISMATCH` (60) — see
[`integration.md`](integration.md)'s note on why this façade cannot itself
produce that status in V1.

**Targeted-provider transfer preview Dictionary**
(`preview_transfer_item_to_provider()`):

```
{
  valid: bool, status: Dictionary,
  destination_container: int64, transferred_quantity: int64,
  conflicting_inventory: int64, authoritative_revision: int64,
}
```

The preview is side-effect-free: it consumes no command id, writes no
idempotency record, advances no revision, and emits no event or delta. A
valid result identifies the first complete destination selected from only
the named provider item's materialized containers. Submission always
re-runs validation against current revisions; preview is feedback, not
authority.

`events[].kind` mirrors `inv::TransactionEventKind` (`native/core/inv_commands.h`,
not ClassDB-bound):

| Value | Kind | | Value | Kind |
|---:|---|---|---:|---|
| 1 | `MOVED` | | 8 | `UNEQUIPPED` |
| 2 | `ROTATED` | | 9 | `SWAPPED` |
| 3 | `SPLIT` | | 10 | `LOOTED` |
| 4 | `MERGED` | | 11 | `DROPPED` |
| 5 | `INSERTED` | | 12 | `REFERENCE_ASSIGNED` |
| 6 | `REMOVED` | | 13 | `REFERENCE_CLEARED` |
| 7 | `EQUIPPED` | | 14 | `COMPONENT_SET` |
| | | | 15 | `COMPONENT_REMOVED` |

**Location Dictionary** (`destination`/`location`/`destination_location`
parameters, and every snapshot item's `location` field —
`native/godot/inventory_godot_util.h`'s `location_dict()`/
`snapshot_location_dict()`):

```
{ kind: "spatial" | "slot" | "list", container: int64, x: int, y: int, rotated: bool, slot_identifier: String, ordinal: int }
```

Only the fields relevant to `kind` are meaningful: `x`/`y`/`rotated` for
`"spatial"`; `slot_identifier` for `"slot"`; `ordinal` for `"list"`.
`container` is always a `ContainerInstanceId` (the numeric `id` field from a
snapshot's `get_containers()` entry), never a definition identifier string.
A malformed `kind` (missing or unrecognized) is rejected with
`STATUS_INVALID_ARGUMENT` before the command reaches the pipeline.

## `InventoryCatalog`

A `RefCounted` (`native/godot/inventory_catalog.h`). Owns one
`inv::DefinitionCatalog` and exposes it only through validate/register/seal/
query methods — there is no accessor that returns a mutable reference to it.
`RefCounted`, not `Node`: a sealed catalog has no per-frame behavior and no
scene-tree owner to guard (matches `gameplay_abilities`'
`GameplayDefinitionValidator` precedent).

### Methods

| Method | Signature | Notes |
|---|---|---|
| `register_builtin_definitions()` | `() -> Dictionary` | Registers the 5 built-in feature modules and 5 built-in trait schemas (`native/core/inv_builtin_features.h`). Safe at most once before `seal()`; a second call, or a call after `seal()`, fails closed with `STATUS_CATALOG_SEALED`. |
| `register_trait_schema(resource)` | `(InventoryTraitSchema) -> Dictionary` | Validates and copies. Returns a catalog diagnostic Dictionary. |
| `register_item(resource)` | `(InventoryItemDefinition) -> Dictionary` | Trait references are validated at `seal()`, not here — an item naming an unregistered trait still reports `STATUS_OK` from this call. |
| `register_container(resource)` | `(InventoryContainerDefinition) -> Dictionary` | Layout dimensions/cardinality ARE validated immediately (e.g. a zero-width spatial grid fails here with `STATUS_INVALID_ARGUMENT`/`GRID_DIMENSION_INVALID`); enabled-feature completeness against the container's own constraints is validated at `seal()`. |
| `register_profile(resource)` | `(InventoryProfileDefinition) -> Dictionary` | An **empty** `root_containers` fails immediately (`STATUS_INVALID_ARGUMENT`/`PROFILE_ROOT_MISSING`); whether those root containers actually exist is validated at `seal()`. |
| `register_catalog_resource(catalog)` | `(InventoryCatalogResource) -> Array[Dictionary]` | One-call registration of every array on `catalog`, in dependency-friendly order (trait schemas, then containers, then items, then profiles). One diagnostic Dictionary per attempted registration, same order. |
| `register_integration_mapping(identifier, canonical_bytes, source = "<script>")` | `(String, PackedByteArray, String) -> Dictionary` | Registers an opaque, adapter-owned canonical mapping payload (e.g. an equipped-trait-to-GAS-grant table from `inventory_gameplay_abilities`) under `identifier`. `canonical_bytes` is trusted to already be canonical — this validates only the identifier and the `MAX_MANIFEST_ENTRY_BYTES` bound, then participates in the sealed manifest and fingerprint like every other registration (`native/core/inv_catalog.h`'s `DefinitionCatalog::register_integration_mapping()`). Pre-seal only: a call after `seal()` fails closed with `STATUS_CATALOG_SEALED`, matching every other `register_*()` method above. |
| `seal()` | `() -> Dictionary` | No further `register_*()` succeeds afterward. Runs full cross-reference validation (trait references, `enabled_features` completeness, feature dependency graph, profile root-container existence) — see `native/core/inv_catalog.cpp`'s `validate_cross_references()`. |
| `is_sealed()` | `() -> bool` | |
| `manifest_fingerprint()` | `() -> int64` | `0` before `seal()` succeeds. A pure function of every registered definition/module/limit — unaffected by registration order (`docs/inventory/contracts.md`, "fnv1a64-canonical-v1"). |
| `api_version()` | `() -> String` | `"major.minor.patch"`, currently `"0.4.0"`. |
| `api_version_major()` / `api_version_minor()` / `api_version_patch()` | `() -> int` | `0` / `4` / `0`. |
| `protocol_version()` | `() -> int` | Currently `1`. |
| `resource_schema_version()` | `() -> int` | Currently `1`. |
| `feature_module_version()` | `() -> int` | Currently `1`. |
| `persistence_schema_version()` | `() -> int` | Currently `1`. |
| `manifest_algorithm()` | `() -> String` | `"fnv1a64-canonical-v1"`. |
| `mass_unit()` | `() -> String` | `"milligram"`. |
| `validate_resource(resource)` | `(Resource) -> Array[Dictionary]` | Runs the SAME validation `register_*()` performs, over a scratch catalog discarded afterward — `resource` is never registered into `this`, and `this`'s own sealed/registered state is unaffected either way. Accepts any of the 4 individual definition types or a full `InventoryCatalogResource`; any other Resource type (including `null`) reports one `STATUS_INVALID_ARGUMENT` finding. For an `InventoryCatalogResource`, the returned array's LAST entry is the scratch catalog's own `seal()` diagnostic (so a cross-reference failure — e.g. an unknown trait — surfaces there, not on the individual entry that caused it; the `identifier` field on that entry names the OFFENDING reference, not the resource that made it). |

### Enums

**`StatusCode`** — mirrors `inv::StatusCode` exactly (append-only):

| Value | Name | | Value | Name |
|---:|---|---|---:|---|
| 0 | `STATUS_OK` | | 24 | `STATUS_CATALOG_SEALED` |
| 1 | `STATUS_INVALID_ARGUMENT` | | 25 | `STATUS_CATALOG_NOT_SEALED` |
| 2 | `STATUS_NOT_FOUND` | | 26 | `STATUS_HASH_COLLISION` |
| 3 | `STATUS_ALREADY_EXISTS` | | 27 | `STATUS_DEPENDENCY_MISSING` |
| 4 | `STATUS_OUT_OF_BOUNDS` | | 28 | `STATUS_DEPENDENCY_CYCLE` |
| 5 | `STATUS_ARITHMETIC_ERROR` | | 29 | `STATUS_INCOMPATIBLE_DEFINITION` |
| 6 | `STATUS_LIMIT_EXCEEDED` | | 40 | `STATUS_MANIFEST_MISMATCH` |
| 7 | `STATUS_NOT_SUPPORTED` | | 41 | `STATUS_PROTOCOL_MISMATCH` |
| 8 | `STATUS_INTERNAL_ERROR` | | 42 | `STATUS_SCHEMA_MISMATCH` |
| 20 | `STATUS_INVALID_IDENTIFIER` | | 43 | `STATUS_FEATURE_UNSUPPORTED` |
| 21 | `STATUS_DUPLICATE_DEFINITION` | | 44 | `STATUS_ENCODE_FAILED` |
| 22 | `STATUS_UNKNOWN_DEFINITION` | | 45 | `STATUS_DECODE_FAILED` |
| 23 | `STATUS_INVALID_REFERENCE` | | 46 | `STATUS_PAYLOAD_TOO_LARGE` |
| | | | 60 | `STATUS_REVISION_MISMATCH` |
| | | | 61 | `STATUS_DUPLICATE_COMMAND` |
| | | | 62 | `STATUS_PERMISSION_DENIED` |
| | | | 63 | `STATUS_ROLE_VIOLATION` |
| | | | 64 | `STATUS_INVARIANT_VIOLATION` |
| | | | 65 | `STATUS_COMMAND_REJECTED` |
| | | | 66 | `STATUS_SNAPSHOT_REQUIRED` |

`inv::DiagnosticId` is deliberately **not** mirrored as a bound enum (same
rationale `InventoryCatalog`'s own header comment gives, matching
`gameplay_abilities`' `GameplayAbilityComponent::StatusCode` precedent) — see
`native/core/inv_status.h` for the full diagnostic-id table.

## `InventoryAuthority`

A `Node` (`native/godot/inventory_authority.h`). Owns one shared
`inv::IdentityAuthority`, one `inv::InventoryTransactionPipeline`, and every
`inv::InventoryRuntime` this instance created or restored, keyed by inventory
id. Every mutation goes through the pipeline's ordered phases (decode/
resolve/revision/policy/structural/feature/simulate/invariant/commit/delta/
notify) — this class never mutates an `InventoryRuntime` directly.

### Properties

| Property | Type | Default | Notes |
|---|---|---|---|
| `role` | `Role` (int enum) | `ROLE_OFFLINE_AUTHORITY` | Immutable once this instance has built its transaction pipeline (i.e. once any inventory has been created or restored). Labeling-only in V1 — see [`integration.md`](integration.md)'s "Authority boundary". |

`catalog` has no `ADD_PROPERTY` (no Inspector entry): `InventoryCatalog` is
`RefCounted`, not `Resource`, so `PROPERTY_HINT_RESOURCE_TYPE`'s file-picker
semantics do not apply. Assign it with `set_catalog()`.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `set_role(role)` / `get_role()` | `(int) -> void` / `() -> int` | |
| `set_catalog(catalog)` / `get_catalog()` | `(InventoryCatalog) -> void` / `() -> InventoryCatalog` | Must reference an already-sealed `InventoryCatalog`. Immutable once the pipeline is built (silent no-op thereafter). |
| `get_last_status()` | `() -> Dictionary` | The `status` of the most recent operation that fails closed by returning a bare `int64`/`PackedByteArray` (`create_inventory`, `snapshot()`, `session_hello_bytes()`, ...) rather than a full result Dictionary. |
| `create_inventory(profile_identifier)` | `(String) -> int64` | Instantiates the profile's root containers as a brand-new, empty (revision 0) inventory. `0` (invalid) plus a recorded diagnostic and a `push_error()` on failure: catalog missing/unsealed, unknown profile, or an aggregate bound exceeded. |
| `has_inventory(inventory_id)` | `(int64) -> bool` | |
| `inventory_revision(inventory_id)` | `(int64) -> int64` | `-1` if unknown. |
| `unload_inventory(inventory_id)` | `(int64) -> Dictionary` | `{ok: bool, status: Dictionary, inventory_id: int64}`. Positive live ids are torn down synchronously: the canonical runtime, that inventory's prepared-reservation records, discovery knowledge/tokens/tasks/intents, accepted-command idempotency entries, and the last delta cache are removed before `inventory_unloaded` is emitted. Unrelated inventories and their state remain intact. Calls from any synchronous authority signal callback fail closed with `STATUS_COMMAND_REJECTED`/`AUTHORITY_LIFECYCLE_BUSY`; matching remote `InventoryReplicaNode` and `InventoryObserverReplicaNode` objects are independently owned and must be disposed by the caller/network bridge. |
| `move_item(inventory_id, item, destination, actor=0, command_id=0)` | `(int64, int64, Dictionary, int64, int64) -> Dictionary` | |
| `rotate_item(inventory_id, item, rotated, actor=0, command_id=0)` | `(int64, int64, bool, int64, int64) -> Dictionary` | Rotate-in-place: same x/y, orientation only. |
| `split_stack(inventory_id, source, quantity, destination, actor=0, command_id=0)` | `(int64, int64, int64, Dictionary, int64, int64) -> Dictionary` | `new_item_id` is the split-off stack. |
| `merge_stacks(inventory_id, source, destination_item, actor=0, command_id=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | `source` is destroyed; `destination_item` survives (its `item` field in the `MERGED` event). |
| `insert_item(inventory_id, item_definition_identifier, quantity, destination, actor=0, command_id=0)` | `(int64, String, int64, Dictionary, int64, int64) -> Dictionary` | Authority-spawn primitive: no source item, spawned by definition identifier. |
| `remove_item(inventory_id, item, actor=0, command_id=0)` | `(int64, int64, int64, int64) -> Dictionary` | Authority-despawn; cascades to any subtree the item provides. |
| `equip_item(inventory_id, item, destination_container, slot_identifier, actor=0, command_id=0)` | `(int64, int64, int64, String, int64, int64) -> Dictionary` | Thin wrapper over move-into-a-`NAMED_SLOTS` container; emits `EQUIPPED` instead of `MOVED`. |
| `unequip_item(inventory_id, item, destination, actor=0, command_id=0)` | `(int64, int64, Dictionary, int64, int64) -> Dictionary` | `destination` may be any layout kind the target container supports. |
| `swap_items(inventory_id, item_a, item_b, actor=0, command_id=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | Atomic exchange of two items' current locations; no caller-supplied destination. |
| `auto_place_item(inventory_id, item, destination_container=0, actor=0, command_id=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | `item` MUST already be present somewhere in `inventory_id` — this reorganizes within one inventory. `destination_container == 0` searches every eligible (`allow_auto_placement`) container in the documented candidate order (`native/core/inv_commands.h`'s `AutoPlaceItemCommand` doc comment); a nonzero value restricts the search to that one container. |
| `quick_transfer_item(source_inventory_id, destination_inventory_id, item, allow_partial=false, actor=0, command_id=0)` | `(int64, int64, int64, bool, int64, int64) -> Dictionary` | Fills compatible existing stacks in the destination first, then auto-places the remainder. `source_inventory_id` may equal `destination_inventory_id` for a same-inventory quick transfer. `allow_partial=false` rejects atomically if the complete quantity cannot be placed. |
| `transfer_item_to_provider(source_inventory_id, destination_inventory_id, item, destination_provider, actor=0, command_id=0)` | `(int64, int64, int64, int64, int64, int64) -> Dictionary` | Complete-only transfer into containers materially provided by `destination_provider`. Within that scope, compatible stacks are filled by ascending item id, then the remainder is placed by ascending provided-container id and the normal per-layout candidate order. Same-inventory reorganization touches one revision; cross-inventory subtree transfer touches both atomically. A failed scoped insertion never becomes swap or loot fallback. |
| `preview_transfer_item_to_provider(source_inventory_id, destination_inventory_id, item, destination_provider, actor=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | Side-effect-free counterpart used by container-item hover feedback. Returns the targeted-provider preview Dictionary documented above and exercises the same bounded placement, access, filter, count, mass, retention, nesting, cycle, permission, and expected-revision validation as submission. |
| `loot_item(source_inventory_id, destination_inventory_id, item, destination_location, actor=0, command_id=0)` | `(int64, int64, int64, Dictionary, int64, int64) -> Dictionary` | Moves `item` and its complete provided-container subtree (ids preserved) as one two-inventory transaction. Always all-or-nothing (`transferred_quantity` is the full quantity, `remaining_quantity` is always `0` on acceptance). |
| `drop_item(inventory_id, item, external_owner, actor=0, command_id=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | Removes `item` and its subtree; hands bounded value data back via `dropped_items`/`dropped_external_owner`. The core never interprets `external_owner`. |
| `settle_inventory(inventory_id, plan, actor=0, command_id=0)` | `(int64, Array, int64, int64) -> Dictionary` | `plan`: `Array[Dictionary{item: int64, disposition: "retain"\|"transfer_to"\|"release_to", destination: int64 (transfer_to), location: Dictionary (transfer_to), external_owner: int64 (release_to)}]`. `retain` requires the item's CURRENT container to already have `PROTECTED`/`BOUND` retention. `transfer_to` validates exactly like `loot_item`; `release_to` exactly like `drop_item`. |
| `assign_reference(inventory_id, item, actor=0, command_id=0)` | `(int64, int64, int64, int64) -> Dictionary` | `new_reference_id` is the new non-owning reference; the item's location is unchanged. |
| `clear_reference(inventory_id, reference, actor=0, command_id=0)` | `(int64, int64, int64, int64) -> Dictionary` | Removes one non-owning reference transactionally. |
| `set_item_component(inventory_id, item, component_identifier, payload, actor=0, command_id=0)` | `(int64, int64, String, PackedByteArray, int64, int64) -> Dictionary` | Sets or replaces one bounded mutable component through the normal permission/revision/idempotency/invariant/delta pipeline. `component_identifier` must be a valid identifier and `payload` is limited by `MAX_TRAIT_PAYLOAD_BYTES`; the accepted event kind is `COMPONENT_SET`. |
| `remove_item_component(inventory_id, item, component_identifier, actor=0, command_id=0)` | `(int64, int64, String, int64, int64) -> Dictionary` | Removes one existing mutable component transactionally; missing components reject atomically, and the accepted event kind is `COMPONENT_REMOVED`. |
| `submit_command_bytes(bytes)` | `(PackedByteArray) -> Dictionary` | Decodes `bytes` as a `protocol::CommandEnvelope` and submits it using the ENVELOPE'S OWN `CommandHeader` (command id, actor, client-declared expected revisions) instead of recomputing the header from current state — the one entry point that exercises the real revision protocol (a stale client-declared revision comes back as `REVISION_MISMATCH`, naming `conflicting_inventory`/`authoritative_revision`, exactly like the typed methods' zero-default fields document but can never trigger). Returns the normal command-result Dictionary plus one extra key, `result_bytes: PackedByteArray` — the reply `protocol::ResultEnvelope`, canonically encoded (empty when the envelope failed to decode or named an unknown inventory). Malformed bytes fail closed with a clean error Dictionary and `get_last_status()` set, never a crash. |
| `encode_move_command_bytes_for_test(inventory_id, item, destination, expected_revision, actor=0, command_id=0)` | `(int64, int64, Dictionary, int64, int64, int64) -> PackedByteArray` | TEST-ONLY: encodes a single-inventory `MoveItemCommand` `CommandEnvelope` with a caller-supplied (possibly stale) `expected_revision`, so a test can drive `submit_command_bytes()`'s real revision-protocol path without a second live peer. Not part of the addon's production surface — a real remote client encodes its own envelope off-box. |
| `encode_quick_transfer_command_bytes_for_test(source_inventory_id, destination_inventory_id, item, allow_partial, source_expected_revision, destination_expected_revision, actor=0, command_id=0)` | `(int64, int64, int64, bool, int64, int64, int64, int64) -> PackedByteArray` | TEST-ONLY: encodes a bounded two-inventory `QuickTransferItemCommand` with explicit source/destination expected revisions. The gateway contract uses it to prove mixed OWNER/REDACTED acknowledgement redaction and filtered owner-delta convergence. It is not production ingress; real remote clients encode protocol envelopes off-box. |
| `snapshot(inventory_id, visibility=VISIBILITY_OWNER)` | `(int64, int) -> InventorySnapshotResource` | `null` on failure (unknown inventory id, encode failure), with `push_error()`/`get_last_status()` set. This is a local/debug value projection for the Resource API: non-owner scopes are not canonical restore input and are not safe to send as an owner snapshot. For recipient transport use `observer_snapshot_envelope_bytes()` and `InventoryObserverReplicaNode`, which apply the policy into the structurally separate observer DTO before encoding. |
| `snapshot_envelope_bytes(inventory_id, visibility=VISIBILITY_OWNER)` | `(int64, int) -> PackedByteArray` | Owner-only canonical transport for `InventoryReplicaNode.apply_snapshot_bytes()`. Non-owner visibility is rejected with a role-violation status because this envelope carries canonical ids/allocator state; use the recipient-bound observer method below for untrusted peers. |
| `observer_snapshot_envelope_bytes(session_id, actor_id, inventory_id, visibility=VISIBILITY_OBSERVER)` | `(int64, int64, int64, int) -> PackedByteArray` | Requires a registered recipient and `VISIBILITY_OBSERVER` or `VISIBILITY_REDACTED`. Applies policy before encoding a dedicated `inventory-observer-v1`/version-1 envelope, binds the exact recipient/inventory/scope stream, and returns the full projected baseline. Registration is lifecycle state, not authentication or authorization; a game gateway must authorize the exact tuple before calling or transmitting it. |
| `observer_delta_bytes(session_id, actor_id, inventory_id, predecessor_sequence)` | `(int64, int64, int64, int64) -> PackedByteArray` | Requires the exact recipient-bound stream baseline. The payload is a complete replacement of the next visible view, not a filtered canonical delta. If only hidden canonical state changed, returns an empty byte array, leaves the recipient sequence unchanged, and reveals no hidden identifier/definition/component/allocator/count information. A sequence mismatch fails closed with `SNAPSHOT_REQUIRED`. |
| `last_delta_batch_bytes()` | `() -> PackedByteArray` | Server-local diagnostic/integration bytes from the most recent ACCEPTED transaction with a non-empty delta set (also carried by `delta_ready`). Never broadcast this raw multi-inventory batch; client egress must be produced per-session/per-inventory through `InventoryNetworkGateway` and permission-filtered. The server-local canonical batch retains `source_command_id`; recipient-filtered OWNER `DeltaBatch` egress clears it to `0` so a global command id cannot correlate other touched inventories or principals. Empty before any such transaction has run. |
| `session_hello_bytes()` | `() -> PackedByteArray` | Encodes a `protocol::SessionHello` for the sealed catalog. Empty if the catalog is missing/unsealed. |
| `make_persistence_record(inventory_id)` | `(int64) -> PackedByteArray` | Empty on failure. |
| `apply_persistence_record(bytes, replace_existing=false)` | `(PackedByteArray, bool) -> Dictionary` | `{ok: bool, status: Dictionary, inventory_id: int64}`. Decodes and installs `bytes`, keyed by the record's OWN encoded inventory id. A live-id collision fails atomically by default; pass `true` only for an explicit live replacement. Successful restores advance the monotonic inventory-id allocator, and script-unrepresentable ids fail closed. A successful live replacement establishes a new runtime generation and invalidates only inventory-scoped reservations, discovery state, accepted commands that touched that inventory (including multi-inventory commands), observer stream state, and the last delta cache when it touched that inventory; unrelated journal/state entries remain valid. The authority emits its replacement lifecycle notification so bridge mirrors invalidate the old same-id generation before accepting new egress. Persistence installation is also rejected while any authority signal is being emitted. |
| `total_mass(inventory_id)` | `(int64) -> Dictionary` | `{ok: bool, status: Dictionary, mass_mg: int64}`. |
| `container_mass(inventory_id, container_id)` | `(int64, int64) -> Dictionary` | `{..., mass_mg: int64}`. |
| `container_mass_capacity(inventory_id, container_id)` | `(int64, int64) -> Dictionary` | `{..., mass_capacity_mg: int64}`. Reports `ok: false` if the container has no declared capacity or the owning profile does not enable `inventory.feature.mass_capacity` — never invents `0` or infinite. |
| `count_in_container(inventory_id, container_id)` | `(int64, int64) -> Dictionary` | `{..., count: int}`. |
| `remaining_count_capacity(inventory_id, container_id)` | `(int64, int64) -> Dictionary` | `{..., remaining: int}`. Same "explicit about unavailability" rule as `container_mass_capacity`. |
| `fits(inventory_id, item_definition_identifier, destination, quantity=1, excluding_item=0)` | `(int64, String, Dictionary, int64, int64) -> Dictionary` | `{ok: bool, status: Dictionary}`. Side-effect-free candidate-placement check. `excluding_item` lets a caller ask "would this fit if this OTHER item (e.g. itself, mid-move) were absent". |
| `has_feature(inventory_id, feature_identifier)` | `(int64, String) -> bool` | Reads the OWNING PROFILE's own `enabled_features` (not any one container's). |

### Signals (4)

| Signal | Payload arg | Notes |
|---|---|---|
| `transaction_committed` | `result: Dictionary` | Fires after EVERY submitted command's pipeline pass completes — accepted, rejected, or replayed alike (the ONLY thing it does not fire for is a `queued: true` reentrant marker itself; the eventual real result fires this signal later, when the pipeline actually drains it). Payload is the exact command-result Dictionary the triggering method call also returned. |
| `delta_ready` | `bytes: PackedByteArray` | Server-local signal only: fires when the just-committed transaction was `accepted` AND produced a non-empty delta set. Its raw multi-inventory bytes are never a client broadcast; use gateway per-session/per-inventory, permission-filtered egress instead. `bytes` equals `last_delta_batch_bytes()` at the moment of the signal and retains `source_command_id`; recipient-filtered OWNER `DeltaBatch` egress clears it to `0` to avoid correlating other touched inventories or principals. |
| `inventory_unloaded` | `inventory_id: int64` | Fires after successful scoped cleanup and runtime erasure. It is a lifecycle notification only; remote `InventoryReplicaNode` and `InventoryObserverReplicaNode` instances are independently owned and the caller/network bridge must dispose the matching mirror. Reentrant unload or persistence installation from this (or any other authority) signal is rejected without mutation. |
| `inventory_generation_changing` | `inventory_id: int64` | Fires for an explicit same-id persistence replacement before the new runtime is made visible. The bound gateway invalidates affected grants/replay state at this edge; bridges must invalidate same-id mirrors and cached egress before accepting the replacement generation. |

### Enums

**`Role`**: `ROLE_OFFLINE_AUTHORITY = 0`, `ROLE_SERVER_AUTHORITY = 1`. See
[`integration.md`](integration.md)'s "Authority boundary" for what does (and
does not) differ between them in this slice.

## `InventoryNetworkGateway`

A server/game-owned, transport-neutral `Node` façade over the authenticated
engine-independent `inv::protocol::InventoryNetworkGateway`. It owns no
`MultiplayerPeer`, socket, RPC endpoint, worker, timer, or packet loop. The
game's transport callback supplies the trusted peer id (in Godot, obtain it
from `get_remote_sender_id()` at the RPC boundary) together with the server's
session, connection epoch, and current tick. **Never take peer, actor,
visibility, or authority from packet fields.** `InventoryAuthority` command
bytes are raw protocol bytes, not RPC messages; the game decides how to move
them and must call this node explicitly from its server-side handler.

The gateway can be attached only to an `InventoryAuthority` whose role is
`ROLE_SERVER_AUTHORITY`. It authenticates a session with the exact
`SessionHello` bytes before admitting commands, push snapshots/deltas, or
resync requests. Logical session ids must be strictly increasing for fresh
sessions within one configured `authority_epoch`; a lower/equal fresh id is
retired and rejected. Reconnect is not a fresh session: it reuses the same
logical session id and exact actor/authority epoch with a strictly higher
`connection_epoch`, requires hello again, and preserves grants, replay
entries, sequence floors, and command/resync rate budgets. Reconnect may use
a different authenticated peer; the gateway moves that complete logical
session state to the new peer and rejects the old-peer/old-epoch context.
The configured positive `authority_epoch` identifies the server authority
generation. A higher authority epoch starts a fresh session-id domain only
after all live sessions in the previous domain are gone; lower/rollback
epochs and live rotation fail closed. The gateway's default command allowlist
is zero (default deny). The six authority-only
classes are hard-rejected from remote gateway ingress:

`INSERT_ITEM`, `REMOVE_ITEM`, `DROP_ITEM`, `SETTLE_INVENTORY`,
`SET_ITEM_COMPONENT`, and `REMOVE_ITEM_COMPONENT`. These six are hard
authority-only and are rejected by remote gateway admission even when their
mask bit is present; a trusted server/game path must invoke the corresponding
authority operation directly after its own policy check.

`CommandEnvelope.header.command_id` is a client-local sequence used only for
that authenticated session's exact-byte replay key. The header's `actor` is
an exact echo of the trusted context check; neither becomes canonical
authority identity. On admission, both are replaced by server-allocated
canonical command id/actor values before `InventoryAuthority` executes the
command. An exact duplicate of an accepted command returns a normalized
`DUPLICATE_RESULT_REPLAY` receipt (`replayed=true`, no events, and no
delta/side-effect bytes) without executing again. Different bytes conflict,
stale/evicted entries are rejected, and an in-flight/re-entrant replay fails
closed. All retained replay bytes, including in-flight reservations, count
against the global 4 MiB replay-byte budget.

Gateway command acknowledgements are deliberately conservative. One-shot
transaction events, canonical delta bytes, and dropped side-effect payloads
are never exposed in a remote acknowledgement. The result always retains
bounded status/admission/replay metadata and `owner_result_scope`; detailed
transaction IDs and revisions (`revisions`, `new_item_id`,
`new_reference_id`, transfer quantities, and conflict inventory/revision) are
retained only when the session has `VISIBILITY_OWNER` replication grants for
every touched inventory. Command permission or an observer/redacted grant
alone produces the minimal acknowledgement and cannot widen that scope.

Revision and policy order is part of the contract: authenticated session and
grant checks happen first, then command decode/identity/class checks, then
the touched inventory's current revision is read, then the mandatory
game-owned world-policy callback runs, and only then can the authority
allocator/executor run. A missing policy callback is a rejection, not an
implicit allow. Malformed and oversize command bytes consume the command
rate bucket before decoding. SessionHello attempts share that authenticated
command-ingress bucket and consume it before hello readiness, size/decode, or
compatibility; malformed and oversized hello attempts therefore consume
budget too. Resync uses a separate bucket. The engine-free limits are 1024
sessions, 256 command grants and 64 engine-free observer grants per session,
256 replay entries per session, 4 MiB retained replay bytes globally (including
in-flight reservations), 32 commands/second, and
16 resync requests/minute at the default 60 ticks/second; all payload,
stream, and generation bounds are fail-closed as documented in
[`../../../docs/inventory/contracts.md`](../../../docs/inventory/contracts.md).
The Godot façade's combined owner plus observer/redacted replication map is
also capped at `MAX_REPLICATION_GRANTS_PER_SESSION = 256`; the engine-free
observer grant map remains capped at 64 entries per session.

The installed world-policy `Callable` is trusted server code. Its evaluation
must be pure with respect to `InventoryAuthority`: it must not submit typed or
raw commands, perform lifecycle operations such as unload or persistence
replacement, mutate quantity reservations, perform discovery mutations, or
make any other authority mutation, and it must not perform external side
effects. The gateway blocks recursive gateway entry, but it cannot generally
roll back arbitrary side effects performed by trusted callback code.

The engine-free/custom `CommandExecutor` callback is synchronous and
immediate. It must not enqueue work or perform any side effects when it
returns a `queued` result; the gateway rejects queued outcomes because they
cannot produce one authoritative reply in the current admission call.

Command grants and replication grants are separate. A command grant never
authorizes an owner packet. `VISIBILITY_OWNER` is an exact owner replication
grant; observer/redacted grants use the dedicated recipient-safe
`inventory-observer-v1` replacement-view protocol. Observer resync derives
visibility from the stored `(session, actor, inventory)` grant, never from a
packet. A configured `generation=0`/`sequence=0` request is the valid
bootstrap scope. For an initialized stream, any structurally valid positive
generation/sequence pair is admitted by the engine-free gateway after its
identity, grant, hello, and rate checks; those request values are informational
and are intentionally not compared with the authority's current predecessor,
because a resync response is always a fresh full baseline. Successful observer
and redacted result Dictionaries expose the generation/sequence carried by
that returned baseline or delta; an empty no-visible-change delta reports the
unchanged current pair. `snapshot_*()` and `delta_*()` are direct,
grant-scoped server egress helpers only: their returned bytes are trusted
server output and must not be exposed as caller-selected visibility or
treated as remote RPC input.

### Properties

| Property | Type | Default | Notes |
|---|---|---:|---|
| `authority_path` | `NodePath` | empty | Path to the server-role `InventoryAuthority`. It is immutable once configured/live. |
| `authority_epoch` | `int64` | `0` | Positive server authority generation; immutable after configuration. |
| `tick_rate` | `int64` | `60` | Positive tick rate used for command/resync rate windows. |

`inventory_authority_path` is an additive setter/getter alias for
`authority_path`; it is not a second binding. `world_policy` is a Callable
set through the methods below (not an Inspector property). The callback is
mandatory and receives the authenticated post-admission policy context
described in `native/protocol/inv_network_gateway.h`; canonical command-id
allocation occurs only after this callback succeeds.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `set_authority_path(path)` / `get_authority_path()` | `(NodePath) -> void` / `() -> NodePath` | Configure the server authority node. |
| `set_inventory_authority_path(path)` / `get_inventory_authority_path()` | `(NodePath) -> void` / `() -> NodePath` | Alias for the authority path. |
| `set_authority_epoch(epoch)` / `get_authority_epoch()` | `(int64) -> bool` / `() -> int64` | Positive immutable authority generation. |
| `set_tick_rate(tick_rate)` / `get_tick_rate()` | `(int64) -> bool` / `() -> int64` | Positive bounded tick rate. |
| `configure(authority_epoch, tick_rate)` | `(int64, int64) -> Dictionary` | Atomically installs the two protocol-domain values. |
| `set_world_policy(policy)` / `get_world_policy()` | `(Callable) -> void` / `() -> Callable` | Installs/reads the mandatory game-owned policy callback. |
| `set_world_policy_callback(policy)` / `get_world_policy_callback()` | `(Callable) -> void` / `() -> Callable` | Alias for the policy callback. |
| `begin_session(peer, session, actor, connection_epoch, command_allowlist=0)` | `(int64, int64, int64, int64, int64) -> Dictionary` | Binds trusted peer/session/actor/connection epoch. Starts default-deny unless the allowlist is explicitly granted. |
| `end_session(peer)` | `(int64) -> Dictionary` | Ends the session bound to a trusted peer and tears down recipient state. |
| `drop_session(session)` | `(int64) -> Dictionary` | Ends a session by its authenticated session id. |
| `clear_sessions()` | `() -> Dictionary` | Clears all authenticated sessions and bounded replay/recipient state. |
| `accept_session_hello(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> Dictionary` | Validates exact protocol/session hello bytes for the already-bound tuple. |
| `admit_session_hello(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> Dictionary` | Terminology alias for `accept_session_hello()`. |
| `set_command_allowlist(session, allowlist)` / `get_command_allowlist(session)` | `(int64, int64) -> Dictionary` / `(int64) -> int64` | Explicit command-class mask; zero is default deny. |
| `session_ready(session)` | `(int64) -> bool` | True only after exact hello admission for the current epochs. |
| `grant_inventory(session, inventory)` / `revoke_inventory(session, inventory)` | `(int64, int64) -> Dictionary` | Grant/revoke command access for one exact inventory. |
| `grant_command_inventory(session, inventory)` / `revoke_command_inventory(session, inventory)` | `(int64, int64) -> Dictionary` | Explicit aliases for command inventory grants. |
| `has_inventory_grant(session, inventory)` | `(int64, int64) -> bool` | Tests the command grant only; it says nothing about replication. |
| `grant_replication(session, inventory, visibility)` | `(int64, int64, int) -> Dictionary` | Stores one exact owner/observer/redacted replication scope. |
| `revoke_replication(session, inventory)` | `(int64, int64) -> Dictionary` | Removes the replication scope. |
| `grant_owner_replication(session, inventory)` | `(int64, int64) -> Dictionary` | Grants `VISIBILITY_OWNER` egress; separate from command access. |
| `grant_observer_replication(session, inventory, visibility=VISIBILITY_OBSERVER)` | `(int64, int64, int) -> Dictionary` | Grants only `VISIBILITY_OBSERVER` or `VISIBILITY_REDACTED` recipient-safe egress. |
| `get_replication_visibility(session, inventory)` | `(int64, int64) -> int` | Returns the stored visibility or the invalid sentinel. |
| `has_replication_grant(session, inventory)` | `(int64, int64) -> bool` | Tests the replication grant only. |
| `submit_command_bytes(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> Dictionary` | Authenticated remote command ingress; packet identity and actor are ignored for trust. |
| `submit_remote_command(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> Dictionary` | Alias for `submit_command_bytes()`. |
| `submit_command(bytes, peer, session, connection_epoch, now_tick=0)` | `(PackedByteArray, int64, int64, int64, int64) -> Dictionary` | Bytes-first script convenience alias; uses the same trusted context. |
| `snapshot_result(session, inventory)` | `(int64, int64) -> Dictionary` | Grant-scoped owner/observer snapshot result for trusted server egress. Requires `session_ready(session)`; a replication grant cannot push before hello admission. |
| `snapshot_bytes(session, inventory)` | `(int64, int64) -> PackedByteArray` | Grant-scoped snapshot bytes for trusted server egress; empty on rejection or a non-ready session. |
| `delta_result(session, inventory, predecessor=0)` | `(int64, int64, int64) -> Dictionary` | Grant-scoped full replacement delta result for a stored replication scope; requires completed exact hello admission for the current epochs. OWNER `DeltaBatch` egress is recipient-filtered and always sets `source_command_id` to `0`; the authority-global id remains only in server-local raw batches so it cannot correlate other touched inventories or principals or undo minimal-ack redaction. |
| `delta_bytes(session, inventory, predecessor=0)` | `(int64, int64, int64) -> PackedByteArray` | Grant-scoped delta bytes for trusted server egress; empty on rejection or until the exact hello is complete for the current epochs. OWNER `DeltaBatch` bytes always clear `source_command_id` to `0`; raw authority batches retain it only for server-local integration. |
| `resync_result(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> Dictionary` | Authenticated owner/observer resync ingress; observer scope comes from the stored grant. Requires the exact `SessionHello` to have completed for the current authority/connection epochs. |
| `resync_bytes(peer, session, connection_epoch, bytes, now_tick=0)` | `(int64, int64, int64, PackedByteArray, int64) -> PackedByteArray` | Bytes-only trusted server response to `resync_result()`; returns no egress until the exact hello is complete for the current epochs. |
| `get_last_status()` | `() -> Dictionary` | Last gateway status for a bare-value failure. |
| `tracked_session_count()` | `() -> int64` | Bounded live-session count. |
| `replay_entry_count(session)` | `(int64) -> int64` | Current bounded exact-byte replay-entry count for one session. |

### Constants

`Visibility` is `VISIBILITY_OWNER = 0`, `VISIBILITY_OBSERVER = 1`, and
`VISIBILITY_REDACTED = 2`. Command class ids are append-only protocol values:

| Class constant | Value | Mask constant | Value |
|---|---:|---|---:|
| `COMMAND_CLASS_MOVE_ITEM` | 1 | `COMMAND_MASK_MOVE_ITEM` | 1 |
| `COMMAND_CLASS_ROTATE_ITEM` | 2 | `COMMAND_MASK_ROTATE_ITEM` | 2 |
| `COMMAND_CLASS_SPLIT_STACK` | 3 | `COMMAND_MASK_SPLIT_STACK` | 4 |
| `COMMAND_CLASS_MERGE_STACKS` | 4 | `COMMAND_MASK_MERGE_STACKS` | 8 |
| `COMMAND_CLASS_INSERT_ITEM` | 5 | `COMMAND_MASK_INSERT_ITEM` | 16 |
| `COMMAND_CLASS_REMOVE_ITEM` | 6 | `COMMAND_MASK_REMOVE_ITEM` | 32 |
| `COMMAND_CLASS_EQUIP_ITEM` | 7 | `COMMAND_MASK_EQUIP_ITEM` | 64 |
| `COMMAND_CLASS_UNEQUIP_ITEM` | 8 | `COMMAND_MASK_UNEQUIP_ITEM` | 128 |
| `COMMAND_CLASS_SWAP_ITEMS` | 9 | `COMMAND_MASK_SWAP_ITEMS` | 256 |
| `COMMAND_CLASS_AUTO_PLACE_ITEM` | 10 | `COMMAND_MASK_AUTO_PLACE_ITEM` | 512 |
| `COMMAND_CLASS_QUICK_TRANSFER_ITEM` | 11 | `COMMAND_MASK_QUICK_TRANSFER_ITEM` | 1024 |
| `COMMAND_CLASS_LOOT_ITEM` | 12 | `COMMAND_MASK_LOOT_ITEM` | 2048 |
| `COMMAND_CLASS_DROP_ITEM` | 13 | `COMMAND_MASK_DROP_ITEM` | 4096 |
| `COMMAND_CLASS_SETTLE_INVENTORY` | 14 | `COMMAND_MASK_SETTLE_INVENTORY` | 8192 |
| `COMMAND_CLASS_ASSIGN_REFERENCE` | 15 | `COMMAND_MASK_ASSIGN_REFERENCE` | 16384 |
| `COMMAND_CLASS_CLEAR_REFERENCE` | 16 | `COMMAND_MASK_CLEAR_REFERENCE` | 32768 |
| `COMMAND_CLASS_TARGETED_PROVIDER_TRANSFER` | 17 | `COMMAND_MASK_TARGETED_PROVIDER_TRANSFER` | 65536 |
| `COMMAND_CLASS_SET_ITEM_COMPONENT` | 18 | `COMMAND_MASK_SET_ITEM_COMPONENT` | 131072 |
| `COMMAND_CLASS_REMOVE_ITEM_COMPONENT` | 19 | `COMMAND_MASK_REMOVE_ITEM_COMPONENT` | 262144 |

`COMMAND_MASK_ALL = 524287`. The six authority-only classes above remain
hard-rejected by remote gateway ingress even when a session has a nonzero
mask. The mask and exact inventory grant govern the other remote command
classes; authority-only operations require a trusted server/game path.
The Godot façade also binds `MAX_REPLICATION_GRANTS_PER_SESSION = 256`, a
combined cap across owner and observer/redacted replication entries. The
engine-free observer grant map remains capped at 64 observer entries per
session; command grants are a separate 256-entry cap.

## `InventoryReplicaNode`

A `Node` (`native/godot/inventory_replica_node.h`) wrapping one
`inv::protocol::InventoryReplica`. Represents exactly ONE remote inventory
per instance. STRUCTURAL role safety, not a runtime check: this class has NO
mutation-command method at all (`inv::protocol::InventoryReplica` has no
`InventoryTransactionPipeline` member and no Command-accepting method) — see
`inventory_probe.gd`/the contract suite's `has_method()` checks for the
executable proof.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `set_catalog(catalog)` / `get_catalog()` | `(InventoryCatalog) -> void` / `() -> InventoryCatalog` | Must be sealed and compatible with the mirrored authority's catalog. Immutable once this instance has applied its first snapshot. |
| `get_inventory_id()` | `() -> int64` | `0` (invalid) before the first successful `apply_snapshot_bytes()`. |
| `get_last_applied_revision()` | `() -> int64` | |
| `needs_resync()` | `() -> bool` | |
| `apply_snapshot_bytes(bytes)` | `(PackedByteArray) -> Dictionary` | `{ok: bool, status: Dictionary}`. Decodes a `protocol::SnapshotEnvelope` and atomically replaces this replica's state. |
| `apply_delta_bytes(bytes)` | `(PackedByteArray) -> Dictionary` | `{ok: bool, applied: bool, status: Dictionary}`. Decodes a `protocol::DeltaBatch`; applies the ONE `InventoryDelta` entry matching this replica's own inventory id, if present. A permission-filtered server message with no matching entry is a harmless no-op (`{ok: true, applied: false}`); never forward raw multi-inventory `InventoryAuthority.delta_ready` bytes to clients. |
| `resync_request_bytes()` | `() -> PackedByteArray` | Encodes a `protocol::ResyncRequest` naming this replica's own inventory id and `last_applied_revision`, for the game's bridge to forward to the authority. Empty before the first snapshot. |
| `snapshot(visibility=VISIBILITY_OWNER)` | `(int) -> InventorySnapshotResource` | Same shape as `InventoryAuthority.snapshot()`, minus the inventory-id argument. |
| `total_mass()` / `container_mass(container_id)` / `container_mass_capacity(container_id)` / `count_in_container(container_id)` / `remaining_count_capacity(container_id)` / `fits(item_definition_identifier, destination, quantity=1, excluding_item=0)` / `has_feature(feature_identifier)` | (identical shapes to `InventoryAuthority`'s query methods, minus the inventory-id argument) | Read-only, identical semantics to the authority-side derived queries. |

### Signals (3)

| Signal | Payload args | Notes |
|---|---|---|
| `snapshot_replaced` | `inventory_id: int64, revision: int64` | Fires exactly once per successful `apply_snapshot_bytes()` — the ONLY event fired for a snapshot, never a per-item/per-op event, covering both "resync after a gap" and "fresh/late-join replica" identically. |
| `delta_applied` | `inventory_id: int64, revision: int64` | Fires once per successfully applied `InventoryDelta` (case 4 of `apply_delta()`'s checked-order contract below). |
| `resync_needed` | `inventory_id: int64, last_applied_revision: int64` | Fires once when a gap or impossible transition is FIRST detected; not re-fired while `needs_resync()` stays `true`. |

### `apply_delta()`'s checked order (informs `apply_delta_bytes()`'s behavior)

From `native/protocol/inv_replica.h`, checked in this exact order (first
match wins) once a batch entry for this replica's inventory id is found:

1. `successor_revision <= last_applied_revision()` → **duplicate**: state
   completely unchanged, `{ok: true, applied: true}` (mirrors
   `TransactionResult`'s own duplicate-replay precedent for "successfully a
   no-op").
2. `needs_resync()` already `true` → state unchanged (still waiting on a
   snapshot), `{ok: false, applied: true}` without re-notifying.
3. `predecessor_revision > last_applied_revision()` → **gap**:
   `needs_resync()` becomes `true`, fires `resync_needed`.
4. `predecessor_revision == last_applied_revision()` → applies every op in
   order onto a clone, audits it, and on success swaps it in, advances
   `last_applied_revision()`, fires `delta_applied`. On ANY op or audit
   failure, this replica's state is completely untouched, `needs_resync()`
   becomes `true`, and `resync_needed` fires.
5. Otherwise → **impossible transition**: same handling as a failed apply in
   case 4.

## `InventoryObserverReplicaNode`

A recipient-only `Node` (`native/godot/inventory_observer_replica_node.h`) that
stores one projected observer value view. It is structurally separate from
`InventoryReplicaNode`: it has no `InventoryRuntime`, canonical snapshot
restore path, allocator state, derived inventory queries, or authority
mutation methods. Its only state transition is installing an already-redacted
observer snapshot or a complete projected successor view.

Configure the exact `(session_id, actor_id, inventory_id, visibility)` tuple
before applying the first packet. The configuration is immutable for the
node's lifetime; a packet naming another recipient, inventory, or visibility
fails closed. `VISIBILITY_OWNER` is not accepted here. The node must have a
sealed compatible catalog, but the catalog is used only to validate the
projected value and manifest — it never provides a canonical restore target.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `set_catalog(catalog)` / `get_catalog()` | `(InventoryCatalog) -> void` / `() -> InventoryCatalog` | Assign a sealed catalog before the first packet. Assignment is ignored after the replica is initialized. |
| `configure_stream(session_id, actor_id, inventory_id, visibility)` | `(int64, int64, int64, int) -> Dictionary` | Required exact stream binding before bootstrap. Accepts only `VISIBILITY_OBSERVER` or `VISIBILITY_REDACTED`; changing it after configuration or initialization fails closed. This binds local packet acceptance only and is not an authentication check. |
| `get_inventory_id()` | `() -> int64` | The configured/accepted inventory id; `0` before a baseline is installed. |
| `get_generation()` | `() -> int64` | Observer stream generation; `0` before a baseline is installed. |
| `get_last_applied_sequence()` | `() -> int64` | Recipient-visible sequence, independent of the authority's canonical inventory revision; `0` before a baseline is installed. |
| `needs_resync()` / `initialized()` | `() -> bool` | `needs_resync()` latches after a gap or invalid successor until a valid full snapshot heals it. |
| `apply_snapshot_bytes(bytes)` | `(PackedByteArray) -> Dictionary` | Decodes only the dedicated `inventory-observer-v1`/version-1 snapshot envelope and atomically replaces the value view. It cannot restore canonical state. |
| `apply_delta_bytes(bytes)` | `(PackedByteArray) -> Dictionary` | Returns `{ok: bool, applied: bool, status: Dictionary}`. Requires an exact predecessor sequence and matching immutable tuple. A duplicate/stale delta is an idempotent `{ok: true, applied: false}` no-op; a gap or malformed successor leaves the view unchanged and requests resync. |
| `resync_request_bytes()` | `() -> PackedByteArray` | Encodes the recipient-bound `ObserverResyncRequest`. The request intentionally carries no visibility authority: it contains the configured recipient/inventory and generation/sequence only. The Task 4.6 gateway must resolve visibility from the authenticated configured `(recipient, inventory)` stream policy/cache, including the `generation=0`/`last_applied_sequence=0` bootstrap case when no cached view exists. After initialization both values are the current positive generation and sequence. Empty only when the stream is not configured or encoding fails. |
| `view()` | `() -> Dictionary` | Returns a plain owned value dictionary, empty before initialization. `manifest_fingerprint` is a decimal `String` so a 64-bit fingerprint is not rounded or made negative by script numeric conversion. The dictionary has `inventory_id`, `visibility`, `generation`, `sequence`, `manifest_fingerprint`, `containers`, and `items`. |

Each `containers` row is `{id, definition_identifier, provider_item,
item_count, aggregate_only}`. Each `items` row is `{id,
item_definition_identifier, quantity, location, mutable_components,
provided_containers}`. Handles are recipient-local opaque values: container
handles and item handles use disjoint high signed-`int64` namespaces and are
not canonical ids or allocator positions. A `REDACTED` stream represents
hidden content only as aggregate-only container shells (and only the policy-
allowed count); it never sends hidden item rows, definitions, quantities,
locations, mutable components, provided-container links, or canonical
references. `OBSERVER` may include fully visible rows where policy permits and
uses the same aggregate-only shape for redacted areas.

### Signals (3)

| Signal | Payload args | Notes |
|---|---|---|
| `snapshot_replaced` | `inventory_id: int64, sequence: int64` | Fires exactly once for each successful full observer snapshot, including the first bootstrap and a resync heal. |
| `delta_applied` | `inventory_id: int64, sequence: int64` | Fires only after a successor replacement view is validated and committed. |
| `resync_needed` | `inventory_id: int64, last_applied_sequence: int64` | Fires once when a gap or impossible transition first latches `needs_resync()`. |

## `InventorySnapshotResource`

An immutable DTO `Resource` (`native/godot/inventory_snapshot_resource.h`).
Every read accessor is generated on demand from a plain, owned
`inv::InventorySnapshot` value copy — never a pointer into
`InventoryRuntime`'s canonical storage, so nothing reachable from script can
mutate authority state through this class. Produced only by
`InventoryAuthority.snapshot()`/`InventoryReplicaNode.snapshot()` — there is
no public constructor path that populates one from script.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `get_inventory_id()` | `() -> int64` | |
| `get_profile_identifier()` | `() -> String` | |
| `get_revision()` | `() -> int64` | |
| `get_manifest_fingerprint()` | `() -> int64` | |
| `get_manifest_algorithm()` | `() -> String` | |
| `get_visibility()` | `() -> int` (`Visibility`) | A local/debug projection tag. Owner canonical envelopes are owner-only; recipient-safe redaction uses `InventoryObserverReplicaNode` and its dedicated observer protocol. |
| `get_containers()` | `() -> Array[Dictionary{id: int64, container_definition_identifier: String, provider_item: int64}]` | Canonical (ascending id) order. `provider_item == 0` means a root container. |
| `get_items()` | `() -> Array[Dictionary{id: int64, item_definition_identifier: String, quantity: int64, location: Dictionary, mutable_components: Array[Dictionary{component_identifier: String, payload: PackedByteArray}], provided_containers: PackedInt64Array}]` | `location` is the Location Dictionary shape documented above. |
| `get_references()` | `() -> Array[Dictionary{id: int64, item_id: int64}]` | |
| `canonical_bytes()` | `() -> PackedByteArray` | Owner-only canonical fixed-width little-endian encoding (`native/core/inv_snapshot.h`). Returns empty for a non-owner projected snapshot; local/debug non-owner Resources must not be transmitted or used as canonical restore input. |
| `hash()` | `() -> int64` | `fnv1a64` over the same canonical encoding, recomputed by the core when the snapshot was produced. A divergence detector, never a security boundary. |

### Enums

**`Visibility`**: `VISIBILITY_OWNER = 0`, `VISIBILITY_OBSERVER = 1`,
`VISIBILITY_REDACTED = 2`.

## Authoring `Resource` classes

Every editor-visible definition type under `native/resources/`. Each is
"pure data" — validated and resolved against the sealed core registries by
`InventoryCatalog` (never by the resource class itself). Full authoring
workflow and identifier rule are in [`authoring.md`](authoring.md); this
section is the property/enum reference only.

### `InventoryTraitSchema`

| Property | Type | Default | Notes |
|---|---|---|---|
| `identifier` | `StringName` | empty | ≥ 2 dotted segments, `[a-z][a-z0-9_]*` per segment. |
| `version` | `int` | `1` | Must match every `InventoryItemTraitValue.version` referencing this schema, checked at `seal()`. |
| `authority_affecting` | `bool` | `true` | `false` marks a purely presentational/cosmetic trait. |
| `max_payload_bytes` | `int` | `1024` | Bounded canonical payload budget for any referencing `InventoryItemTraitValue`. |

### `InventoryItemTraitValue`

| Property | Type | Default | Notes |
|---|---|---|---|
| `trait_identifier` | `StringName` | empty | Must name an `InventoryTraitSchema` registered in the same catalog (validated at `seal()`, never at registration). |
| `version` | `int` | `1` | |
| `payload` | `PackedByteArray` | empty | Opaque canonical bytes; not interpreted beyond bounding it against the schema's `max_payload_bytes`. |

### `InventoryItemDefinition`

| Property | Type | Default | Notes |
|---|---|---|---|
| `identifier` | `StringName` | empty | |
| `schema_version` | `int` | `1` | |
| `max_stack` | `int64` | `1` | `1` means "does not stack". |
| `unit_mass_mg` | `int64` | `0` | Checked signed 64-bit milligrams. Never a float. |
| `footprint_width` / `footprint_height` | `int` | `1` / `1` | |
| `allow_rotation` | `bool` | `false` | |
| `traits` | `Array[InventoryItemTraitValue]` | empty | |
| `provided_containers` | `PackedStringArray` | empty | Identifiers of `InventoryContainerDefinition`s this item provides when equipped/placed. |

### `InventoryNamedSlot`

| Property | Type | Default | Notes |
|---|---|---|---|
| `identifier` | `StringName` | empty | |
| `max_items` | `int` | `1` | |
| `required_traits` / `blocked_traits` | `PackedStringArray` | empty | Trait-schema references, validated at `seal()`. |

### `InventoryContainerConstraints`

| Property | Type | Default | Notes |
|---|---|---|---|
| `max_items` | `int` | `0` | `0` inherits the profile's hard bound. |
| `has_mass_capacity` | `bool` | `false` | |
| `mass_capacity_mg` | `int64` | `0` | Meaningful only when `has_mass_capacity` AND the profile enables `inventory.feature.mass_capacity`. |
| `required_traits` / `blocked_traits` | `PackedStringArray` | empty | |
| `allow_nesting` | `bool` | `false` | |
| `max_nesting_depth` | `int` | `0` | |
| `access_mask` | `int` (bitfield) | `ACCESS_INSERT \| ACCESS_REMOVE \| ACCESS_MOVE \| ACCESS_INSPECT` | See `AccessFlagBits` below. |
| `retention` | `Retention` (int enum) | `RETENTION_NONE` | |
| `allow_stack_split` | `bool` | `false` | Gates `split_stack`; also requires `inventory.feature.stacking` in the container's `enabled_features`. |
| `allow_auto_placement` | `bool` | `false` | Container is a candidate for `auto_place_item`/`quick_transfer_item`'s remainder placement. |
| `allow_quick_transfer` | `bool` | `false` | Declarative — see [`integration.md`](integration.md)'s note that this bool does not itself gate `quick_transfer_item` at the transaction-pipeline level in V1; it only affects `required_container_features()`'s computed `enabled_features` requirement. |

**`Retention`**: `RETENTION_NONE = 0`, `RETENTION_PROTECTED = 1`,
`RETENTION_BOUND = 2`.

**`AccessFlagBits`** (bitfield, mirrors `inv::AccessFlag`; bound via
`BIND_BITFIELD_FLAG`/`VARIANT_BITFIELD_CAST` — see the "Enum binding fix"
note below): `ACCESS_INSERT = 1`, `ACCESS_REMOVE = 2`, `ACCESS_MOVE = 4`,
`ACCESS_INSPECT = 8`. GDScript/C# reference these by name, e.g.
`InventoryContainerConstraints.ACCESS_INSERT`.

> **Enum binding fix (task 7.6):** prior to this change, `AccessFlagBits` was
> declared in the header with a comment but had NO `VARIANT_ENUM_CAST`/
> `BIND_BITFIELD_FLAG` binding at all, so `InventoryContainerConstraints.ACCESS_INSERT`
> etc. did not exist as GDScript-visible names — a caller had to hard-code the
> raw integers `1`/`2`/`4`/`8`. This is now bound the same way
> `InventoryContainerConstraints.Retention` already was, but using the
> BITFIELD variant (`VARIANT_BITFIELD_CAST`/`BIND_BITFIELD_FLAG`) rather than
> the plain-enum variant, since these four values combine as a mask rather
> than selecting one of a closed set. The contract test suite
> (`tests/inventory_system/contract/inv_contract_main.gd`) authors its vault/
> backpack fixtures' `access_mask` using the named constants as the
> executable proof.

### `InventoryContainerDefinition`

A container selects exactly ONE ownership layout via `layout_kind`; only the
fields relevant to the selected layout are meaningful (`_validate_property`
hides the rest in the Inspector).

| Property | Type | Default | Notes |
|---|---|---|---|
| `identifier` | `StringName` | empty | |
| `schema_version` | `int` | `1` | |
| `layout_kind` | `LayoutKind` (int enum) | `LAYOUT_SPATIAL_GRID` | |
| `grid_width` / `grid_height` | `int` | `1` / `1` | `SPATIAL_GRID` only. A `0` dimension fails registration immediately (`GRID_DIMENSION_INVALID`). |
| `grid_allow_rotation` | `bool` | `false` | `SPATIAL_GRID` only. |
| `named_slots` | `Array[InventoryNamedSlot]` | empty | `NAMED_SLOTS` only. |
| `ordered_list_max_entries` | `int` | `1` | `ORDERED_LIST` only. |
| `enabled_features` | `PackedStringArray` | empty | Identifiers of `inventory.feature.*` modules this container activates. Must be a SUPERSET of every feature the layout/constraints structurally require, verified at `seal()` (see [`authoring.md`](authoring.md)'s worked feature-derivation table). |
| `constraints` | `InventoryContainerConstraints` | `null` | `null` behaves like a default-constructed `InventoryContainerConstraints` (full access, no capacity/filter/nesting/retention). |
| `discovery_policy_identifier` | `StringName` | empty | Empty preserves instant-open behavior. A value names a registered `InventoryDiscoveryPolicy` and requires `inventory.feature.discovery` on this container and its active profile. |

**`LayoutKind`**: `LAYOUT_SPATIAL_GRID = 0`, `LAYOUT_NAMED_SLOTS = 1`,
`LAYOUT_ORDERED_LIST = 2` (mirrors `inv::OwnershipLayoutKind`'s
`SPATIAL_GRID=1, NAMED_SLOTS=2, ORDERED_LIST=3` via an explicit conversion,
not the raw values).

### `InventoryProfileLimits`

| Property | Type | Default |
|---|---|---|
| `max_items` | `int` | `4096` |
| `max_containers` | `int` | `512` |
| `max_references` | `int` | `256` |
| `max_nesting_depth` | `int` | `16` |
| `max_mutable_components_per_item` | `int` | `32` |

Defaults mirror the current compiled-in hard bounds
(`native/core/inv_limits.h`); a profile may lower these but the core
re-validates that a lowered value never exceeds the hard limit.

### `InventoryProfileDefinition`

| Property | Type | Default | Notes |
|---|---|---|---|
| `identifier` | `StringName` | empty | |
| `schema_version` | `int` | `1` | |
| `root_containers` | `PackedStringArray` | empty | Identifiers of `InventoryContainerDefinition`s instantiated as this profile's root containers. **Cannot be empty** — fails registration immediately with `PROFILE_ROOT_MISSING`. |
| `enabled_features` | `PackedStringArray` | empty | Identifiers of `inventory.feature.*` modules this profile enables — this is what `InventoryAuthority.has_feature()`/`InventoryReplicaNode.has_feature()` read; independent of any one container's own `enabled_features`. |
| `limits` | `InventoryProfileLimits` | `null` | `null` registers with the core's compiled-in hard defaults. |

### `InventoryCatalogResource`

Aggregates every authoring definition for one-call registration
(`InventoryCatalog.register_catalog_resource()`). Named
`InventoryCatalogResource` (rather than `InventoryCatalog`) to avoid
colliding with the façade's own `InventoryCatalog` `RefCounted`.

| Property | Type |
|---|---|
| `trait_schemas` | `Array[InventoryTraitSchema]` |
| `discovery_policies` | `Array[InventoryDiscoveryPolicy]` |
| `items` | `Array[InventoryItemDefinition]` |
| `containers` | `Array[InventoryContainerDefinition]` |
| `profiles` | `Array[InventoryProfileDefinition]` |
