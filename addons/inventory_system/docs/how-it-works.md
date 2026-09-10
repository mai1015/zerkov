# How the Inventory System Works

This guide is the shortest path to a correct mental model of the addon. It is
written for a game developer using the Godot-facing API, not for someone
maintaining the native implementation. Start here, then use
[`authoring.md`](authoring.md) for every resource field,
[`api.md`](api.md) for the primary façade reference,
[`discovery.md`](discovery.md) for the optional discovery surface,
[`generated/`](generated/) for the exhaustive bound-class inventory, and
[`integration.md`](integration.md) for production networking and persistence.

The addon is a required native GDExtension for Godot 4.7 or newer. There is no
GDScript fallback. Its public API is currently pre-1.0, so pin the addon version
and read [`compatibility.md`](compatibility.md) before shipping saved data or a
network protocol that must survive upgrades.

## The model in one minute

The system separates four jobs that are often mixed together in inventory
code:

```text
authoring Resources
        |
        v  validate, copy, resolve references, seal
 InventoryCatalog ---------------------> manifest fingerprint
        |
        v  choose a profile
 InventoryAuthority
        |
        +-- owns canonical InventoryRuntime state
        +-- accepts commands through an atomic transaction pipeline
        +-- returns receipts and immutable snapshots
        +-- emits authoritative deltas after accepted commits
        |
        +------------------ local/offline ---------------------> UI host
        |
        `-- InventoryNetworkGateway -- game transport --------> replicas
                                                               |
                                                               v
                                            presentation model + controls
```

The rules to keep in mind are:

- Definitions describe what may exist. Runtime instances describe what exists
  now.
- `InventoryAuthority` is the only owner of mutable canonical state.
- Commands are requests. A command has no effect unless its receipt says
  `accepted == true`.
- A rejection is atomic: canonical state and revisions do not change.
- Snapshots and deltas are owned values, not live references into authority
  storage.
- Presentation renders snapshots and submits intent. It never edits canonical
  item dictionaries in place.
- Networking is transport-neutral. The game owns authentication, RPCs or
  sockets, routing, and world policy.

## 1. Definitions become a sealed catalog

You author pure-data `Resource` objects and register them with an
`InventoryCatalog`:

| Definition | What it decides |
|---|---|
| `InventoryTraitSchema` | The identity, version, authority relevance, and byte budget of a trait. |
| `InventoryItemDefinition` | Stack maximum, integer mass in milligrams, grid footprint, rotation, traits, and any containers the item provides. |
| `InventoryContainerDefinition` | One layout, its capacity/access/filter/nesting rules, enabled features, and optional discovery policy. |
| `InventoryProfileDefinition` | Which root containers a new inventory starts with, profile-wide features, and aggregate limits. |
| `InventoryDiscoveryPolicy` | Search/Scan timing and presentation-safe shell text for optional recipient-scoped discovery. |
| `InventoryCatalogResource` | A convenient bundle of the definitions above for one-call registration. |

The resources are authoring inputs, not live runtime objects. Registration
validates and copies their current values into the native catalog. Mutating an
item or container resource after registration cannot change a sealed catalog.

Call `register_builtin_definitions()` once before `seal()`; calling it before
game definitions is the clearest bootstrap order, although registration order
does not change the sealed result. Built-ins supply the `inventory.feature.*`
modules and common `inventory.trait.*` schemas used by container rules. Staged
discovery is opt-in; a catalog resource with discovery policies registers its
companion feature through the catalog-resource path.

`seal()` is the important boundary. It:

1. resolves cross-references such as profile roots, traits, provided
   containers, discovery policies, and feature dependencies;
2. verifies that each container enabled every feature required by its layout
   and constraints;
3. canonicalizes definition identity and builds a content manifest;
4. produces a deterministic manifest fingerprint; and
5. makes the catalog immutable.

An authority cannot create an inventory from an unsealed catalog. A peer also
cannot safely exchange canonical inventory state with a different catalog:
the manifest fingerprint and the independent protocol/schema versions are
part of compatibility admission.

### Stable identifiers versus runtime handles

Definitions use portable strings such as `game.item.ration` and
`game.container.pouch`. These strings survive saves and identify the same
definition on another compatible peer.

Runtime objects use positive integer handles:

- inventory id;
- item instance id;
- container instance id; and
- non-owning reference id.

These are distinct domains even though GDScript represents all of them as
`int64`. Zero is the invalid handle. Never pass a definition identifier where
a location expects a container instance id, and never infer meaning from the
numeric value of a handle.

## 2. A profile creates one runtime inventory

`InventoryAuthority.create_inventory(profile_identifier)` allocates an
inventory id and creates one `InventoryRuntime` from the sealed profile. The
runtime starts at revision `0`, with:

- one container instance for each profile root-container definition;
- no item instances; and
- no non-owning references.

The authority owns every runtime it creates or restores. It also owns shared
item, container, reference, inventory, and command identity allocation, so the
game should treat returned ids as opaque authority-issued values.

The profile and definitions stay fixed for that runtime. During ordinary play,
current state—the items, quantities, placements, mutable components,
references, provided containers, and revision—changes only through accepted
authority commands. The advanced prepared-quantity participant described
below is the deliberate exception: it can stage a consumption before
publishing the corresponding authoritative delta.

### Roots, provider items, and nested containers

A root container belongs directly to the inventory. Its snapshot row has
`provider_item == 0`.

An item definition may list `provided_containers`. Creating an instance of
that item also materializes container instances for those definitions. A
backpack item can therefore provide its own grid, a rig can provide named
slots, and a case can provide an ordered list. Each provided container records
the item instance that owns it, and it moves implicitly with that item.

This ownership is structural, not a UI convention:

- moving a provider moves the complete nested ownership subtree;
- a cross-inventory loot or settlement transfer preserves the subtree's
  instance ids and commits both inventories atomically;
- removing or dropping a provider removes its descendants and clears
  references to anything removed; and
- cycle checks and both container/profile nesting limits prevent an item from
  being placed inside its own descendants.

Revealing or opening a provider item in the UI does not create its container.
The container already exists canonically; presentation is only deciding
whether and how to show it.

## 3. Every item has exactly one owning placement

Every item instance has one location. Godot represents it with this dictionary
shape:

```gdscript
{
    "kind": "spatial" | "slot" | "list",
    "container": container_instance_id,
    "x": 0,
    "y": 0,
    "rotated": false,
    "slot_identifier": "",
    "ordinal": 0,
}
```

Only the fields for the selected `kind` matter.

| Layout | Placement meaning | Validation |
|---|---|---|
| Spatial grid | `(x, y)` is the item's origin; `rotated` swaps its effective footprint. | Layout kind, item and grid rotation permission, bounds, rectangle overlap, filters, and capacity are checked. |
| Named slots | `slot_identifier` names a slot declared by the container definition. | Slot existence, slot-specific filters and occupancy, container filters, and capacity are checked. |
| Ordered list | `ordinal` is an insertion position from `0` through the current filtered size. | List capacity and ordinal bounds are checked; insertions shift entries and removals re-densify ordinals. |

Container constraints add access flags, item-count capacity, integer mass
capacity, trait filters, nesting, retention, split permission, and participation
in automatic placement. The corresponding `inventory.feature.*` module must be
enabled where the authoring contract requires it; this is verified when the
catalog is sealed.

Mass is always authoritative integer milligrams. Do not convert an authored
float at runtime and expect deterministic agreement between peers.

### Deterministic automatic placement

`auto_place_item()` reorganizes an item already in an inventory.
`quick_transfer_item()` first fills compatible existing stacks and then uses
the same placement search for a remainder. Given identical state, the search
always chooses the same first valid location:

1. eligible root containers, sorted by container-definition identifier;
2. eligible item-provided containers, in ascending container instance id;
3. inside a grid, unrotated row-major cells, then rotated row-major cells;
4. inside named slots, declaration order; or
5. inside an ordered list, append at the end.

A nonzero `destination_container` restricts auto-placement to that exact
container. If no candidate satisfies every rule, the command rejects; it does
not invent a fallback.

### Stack behavior

Quantity belongs to an item instance. Its definition's `max_stack` is the hard
upper bound; `1` means the item does not stack.

- `split_stack()` reduces the source and creates a new item instance at an
  explicitly validated destination. The source container must allow splitting.
- `merge_stacks()` requires compatible definitions and available space. The
  destination instance survives and the source instance is removed. Both
  stacks must have identical mutable-component state, and neither may own
  provided containers.
- Quick transfer fills compatible destination stacks in ascending item id
  before considering a new destination stack.
- With `allow_partial == false`, quick transfer is all-or-nothing. With
  `allow_partial == true`, the receipt reports `transferred_quantity` and
  `remaining_quantity`.
- In the current contract, one quick-transfer remainder is not spread across
  several newly created stacks. If it cannot fit as one new stack, only the
  allowed partial portion can commit.

## 4. Commands run through one atomic pipeline

The Godot typed methods—`move_item()`, `split_stack()`, `insert_item()`,
`quick_transfer_item()`, and the rest—convert their arguments into a command
value and submit it to the same native pipeline.

The command families are:

| Intent | Methods | Resulting behavior |
|---|---|---|
| Place or equip | `move_item()`, `rotate_item()`, `equip_item()`, `unequip_item()`, `swap_items()` | Change owning locations after validating both the old and final placements. Equip/unequip are named-slot moves with semantic event kinds; swap validates the final exchange atomically, without requiring either intermediate move to fit. |
| Create or destroy | `insert_item()`, `remove_item()` | Trusted authority spawn/despawn by definition or instance. Removing a provider cascades through its ownership subtree. |
| Work with stacks | `split_stack()`, `merge_stacks()` | Create a second bounded stack or coalesce two compatible stack identities. |
| Choose a destination | `auto_place_item()`, `quick_transfer_item()`, `transfer_item_to_provider()` | Use the deterministic candidate order. Provider-targeted transfer searches only the containers materially owned by the named provider and never falls back outside that scope. |
| Move between inventories | `loot_item()` | Move one complete item/provider subtree, preserving ids, as an all-or-nothing two-inventory commit. |
| Leave inventory ownership | `drop_item()`, `settle_inventory()` | Return bounded item value records to game-owned external ownership. The core treats `external_owner` as an opaque positive id; the game decides what world entity, stash, raid result, or account it means. |
| Add a non-owning pointer | `assign_reference()`, `clear_reference()` | Create or remove a reference without changing the item's owning location. References are cleared automatically when their item leaves that inventory. |
| Change bounded instance state | `set_item_component()`, `remove_item_component()` | Set or remove an opaque, identifier-keyed component payload through the same revision, policy, invariant, event, and delta path. |

`settle_inventory()` is the batch policy boundary for extraction/death/raid
resolution. Each plan entry says retain, transfer to another inventory, or
release to external ownership. The complete bounded plan is one transaction;
a failure rejects the whole plan. Retain is accepted only for items already in
a `PROTECTED` or `BOUND` container—the client cannot simply declare an item
protected.

For a normal non-reentrant command, the ordered phases are:

| Phase | What happens |
|---:|---|
| 0 | Validate the command id and check the accepted-command idempotency journal. |
| 1 | Resolve every referenced inventory, item, container, definition, and other target. |
| 2 | Check the exact expected revision set. |
| 3 | Run permission policy and any external-metric policy. |
| 4 | Check command-specific structure. |
| 5 | Check access, filters, count, mass, nesting, stack, and retention constraints in canonical order. |
| 6 | Apply the operation to cloned runtime state. |
| 7 | Audit every invariant on the clone. |
| 8 | Replace canonical state and increment each touched inventory revision exactly once. |
| 9 | Build the receipt, semantic events, and per-inventory deltas. |
| 10 | Notify observers after the commit. |

Phases before simulation are read-only. Simulation changes only clones. If
anything through the invariant audit fails, no clone is installed, so the
original runtime and its revision remain unchanged.

Direct Godot calls currently use the core's allow-all permission provider.
Their `actor` argument is opaque audit/policy context, not authentication and
not an access check. Only trusted game code should call typed authority
methods; perform game policy before the call. Remote byte ingress should go
through `InventoryNetworkGateway`, whose world-policy callback is mandatory.

Multi-inventory commands resolve all touched runtimes, order them by inventory
id, require compatible shared identity authority, validate every clone, and
commit all touched inventories or none of them. This is why looting a backpack
subtree cannot disappear from the source while failing to appear in the
destination.

### Prepared quantity reservations are a separate participant

The authority also exposes a trusted, authority-only reservation flow for a
coordinator that must consume an exact quantity together with another system,
such as crafting, trading, or weapon reload. It is not a remotely admitted
command class and does not use the normal command-receipt lifecycle:

1. `prepare_quantity_reservation()` takes the inventory, a unique reservation
   id, required trait, ordered container-definition priorities, quantity, and
   optional expected revision and deadline. It selects matching quantities by
   those priorities, then by ascending item id, without changing inventory
   state or revision. `expected_revision=-1` means current;
   `deadline_tick=0` means no expiry, using a game-owned monotonic clock.
2. Ordinary commands that would move, destroy, merge, or otherwise change a
   held line reject. Unrelated items remain usable, and a split may consume
   only the provably unheld part of a stack if the held quantity stays on the
   original item id.
3. `commit_quantity_reservation_silent()` validates the held lines against
   their current quantities, consumes them on a clone, and advances the
   inventory revision. It deliberately emits no transaction or delta yet and
   retains the immediate predecessor for rollback.
4. The coordinator then calls `publish_quantity_reservation()` to make that
   already-committed change observable through `transaction_committed`,
   `delta_ready`, and `quantity_reservation_published`, or calls
   `rollback_quantity_reservation()` while the silent successor is still the
   current revision. Do not allow unrelated mutations in this short
   commit-to-publish/rollback window.
5. `release_quantity_reservation()` drops an uncommitted hold.
   `expire_quantity_reservation()` releases a due hold or, while its silent
   successor is still current, rolls back a due unpublished commit.
   `health_quantity_reservation()` and
   `active_quantity_reservation_count()` are read-only diagnostics.

Every call exposes `accepted` and `status`. Once catalog and inventory lookup
reach the reservation participant, its result also contains `replayed`,
`reservation_id`, `inventory_id`, `revision`, `quantity`, `lines`, and
`stage`. The stage values are `1` held, `2` committed, `3` released, and `4`
published (`0` means unknown). Reuse one reservation id only for an exact
replay of the same logical request.

### Revisions and command ids

Typed `InventoryAuthority` calls capture the current revision immediately
before submission. They are ideal for trusted local/offline code, but they do
not model a stale remote client's earlier view. `submit_command_bytes()` keeps
the expected revisions encoded by the sender and is the path that can return a
real `STATUS_REVISION_MISMATCH`.

Passing `command_id <= 0` to a typed method asks the authority to allocate one.
Pass an explicit positive id when a presentation model or transport needs to
correlate an intent with its result.

An exact repeat of an already accepted command id and payload returns the
recorded outcome as `replayed == true` without mutating again and without
re-emitting the original events or deltas. Reusing that id with a different
payload is rejected. Treat a command id as the identity of one logical
operation, not as a convenient constant.

If a signal callback submits another command while the pipeline is notifying,
the nested submission returns a `queued == true` marker. The real command runs
later from a bounded FIFO and revalidates against the then-current revision.
Observe `transaction_committed` for its eventual result; do not treat the
queued marker as acceptance.

## 5. Read the command receipt correctly

Every typed command returns one stable-shaped dictionary. The most useful
fields are:

```text
{
    accepted: bool, replayed: bool, queued: bool,
    status: {code: int, diagnostic: int, detail: int64, ok: bool},
    command_id: int64,
    revisions: Array[{inventory, predecessor, successor}],
    events: Array[{kind, item, secondary_item, source_container,
                   destination_container, reference}],
    new_item_id: int64, new_reference_id: int64,
    transferred_quantity: int64, remaining_quantity: int64,
    conflicting_inventory: int64, authoritative_revision: int64,
}
```

Interpret it in this order:

1. If `queued` is true, wait for the later signal result.
2. If `replayed` is true, the operation was already decided; do not replay UI
   one-shot effects.
3. If `accepted` is false, show or log `status` and refresh/resync when the
   status requires it. State did not partially change.
4. If `accepted` is true, `revisions` names each committed predecessor and
   successor. Command-specific return fields may now be meaningful.

`events` are semantic, one-shot facts such as moved, split, equipped, looted,
or reference assigned. They are useful for animation, audio, gameplay adapters,
and feedback. They are not a persistence or replication format.

Deltas are complete after-state operations used to converge a replica. They
are produced only for the first accepted execution, one delta per touched
inventory. A rejected or replayed command produces no delta. The raw batch
cached by `InventoryAuthority.last_delta_batch_bytes()` and emitted through
`delta_ready` is server-local and may contain several inventories; do not
broadcast it directly to arbitrary clients.

Methods returning only an id, byte array, snapshot, or other bare value cannot
embed a full error. Check `InventoryAuthority.get_last_status()` or
`InventoryNetworkGateway.get_last_status()` when a bare return from that
object is invalid or empty. Replica apply methods return their status directly
in a dictionary.

## 6. Snapshots are the read model

`authority.snapshot(inventory_id)` creates an immutable
`InventorySnapshotResource`. It is a deep value copy containing the inventory
identity, profile, manifest identity, revision, containers, items, references,
and a deterministic hash. Nothing exposed by the snapshot aliases mutable
authority storage.

The usual UI loop is therefore:

1. keep the most recent accepted snapshot;
2. render its containers and items;
3. capture user intent against that revision;
4. submit a command;
5. reconcile its receipt; and
6. obtain the new snapshot after acceptance, or replace from network state.

Side-effect-free queries such as `fits()`, `total_mass()`,
`container_mass()`, `remaining_count_capacity()`, and `has_feature()` provide
authoritative answers without exposing runtime internals. A preview is still
advisory: the final command reruns all validation against current state.

The snapshot hash and catalog manifest fingerprint detect divergence; they are
not cryptographic authentication or tamper protection.

### Owner snapshots versus observer views

There are two deliberately separate replication models:

| Recipient | Transport value | Client holder | Meaning |
|---|---|---|---|
| Owner | Canonical `SnapshotEnvelope` plus ordered `DeltaBatch` values | `InventoryReplicaNode` | A complete restorable inventory mirror with canonical ids and derived queries. |
| Observer/redacted | Recipient-bound `inventory-observer-v1` snapshots and replacement-view deltas | `InventoryObserverReplicaNode` | A projected value view with opaque local handles and no canonical restore or mutation path. |

`snapshot_envelope_bytes()` is owner-only. A local
`snapshot(..., VISIBILITY_OBSERVER)` value is useful for trusted inspection,
but it is not the recipient-safe wire protocol. Untrusted observer output must
come through the gateway/observer methods and be applied only to an
`InventoryObserverReplicaNode` configured for the exact session, actor,
inventory, and visibility tuple.

A redacted observer view can contain aggregate-only container shells. It never
contains hidden item rows, definitions, quantities, placements, components,
provider links, references, allocator state, or canonical ids. If a canonical
mutation changes only hidden information, the observer stream emits no bytes
and does not advance its visible sequence.

## 7. Replication is explicit and transport-neutral

The addon does not create a `MultiplayerPeer`, RPC method, socket, packet loop,
or authentication system. Your game transports the byte arrays produced by
the façade.

### Owner replica flow

The ordinary full-owner flow is:

```text
server InventoryAuthority
        |
        | owner snapshot bytes (bootstrap or resync)
        | filtered owner delta bytes (subsequent commits)
        v
game-owned authenticated transport
        v
client InventoryReplicaNode (exactly one inventory)
        |
        v
immutable snapshot -> presentation
```

The replica applies a full snapshot atomically. A delta applies only when its
predecessor matches `last_applied_revision`. Duplicates are harmless no-ops.
A gap or impossible transition latches `needs_resync()` and emits
`resync_needed`; fetch and apply a fresh full snapshot before accepting more
deltas. Applying a snapshot replaces state once—it does not replay historical
per-item events.

### What `InventoryNetworkGateway` owns

For remote use, place an `InventoryNetworkGateway` beside a
`ROLE_SERVER_AUTHORITY` authority. The gateway owns bounded network-facing
session state, not inventory state or transport:

- trusted peer/session/actor/connection-epoch bindings;
- exact `SessionHello` compatibility admission;
- separate command-inventory and replication grants;
- a default-deny command-class allowlist;
- exact-byte replay protection and rate budgets;
- a mandatory game-owned world-policy callback; and
- owner versus observer/redacted egress selection.

The trusted peer id must come from the transport boundary (for a Godot RPC,
use `multiplayer.get_remote_sender_id()`), never from fields supplied by the
client. The packet's actor and command id are claims, not canonical authority
identity; the gateway validates the claim context and replaces execution
identity with server-issued values.

Command permission and replication permission are independent. Granting a
player permission to move an item does not grant owner snapshots. Likewise,
an observer grant does not grant commands.

Remote ingress hard-rejects the authority-only insert, remove, drop,
settlement, and mutable-component commands even if their mask bit is present.
Trusted server gameplay may call those authority methods directly after its
own policy checks.

The production sequence is:

1. configure the gateway with a positive authority epoch and tick rate;
2. install a pure, mandatory `world_policy` callback;
3. authenticate a connection in game code;
4. `begin_session()` with trusted context;
5. grant exact command and replication scopes;
6. exchange and admit exact `session_hello_bytes()`;
7. route remote command bytes through gateway admission; and
8. send only grant-scoped `snapshot_bytes()`, `delta_bytes()`, or resync
   responses back through the game transport.

See [`integration.md`](integration.md)
for a runnable-shaped server setup and [`api.md`](api.md#inventorynetworkgateway)
for the full grant and session surface.

## 8. Staged discovery is a separate disclosure state machine

Staged discovery is optional. It is for containers whose contents should not
be immediately knowable to a recipient, such as searchable loot crates.
Discovery does not change item ownership or placement, so it has its own
recipient-scoped revision alongside the canonical inventory revision.

The lifecycle is:

```text
unsearched shell --Search--> searching --trusted time--> indexed entries
indexed entry   --Scan-----> scanning  --trusted time--> revealed item
```

Before indexing, the recipient receives only a presentation-safe shell and an
opaque container token. Indexing can disclose layout/count information and
opaque entry tokens. Scanning one entry can disclose its item through the
ordinary projected view. Revealing a provider item may expose its child
container as a new unsearched shell; it does not recursively reveal contents.

The game authenticates first, then registers a `(session_id, actor_id)`
recipient. Search, scan, and cancel intents carry opaque tokens plus expected
canonical and discovery revisions. Only trusted server/offline code advances
elapsed discovery time. There is intentionally no client "complete now"
method.

Registration is lifecycle bookkeeping, not authentication. Tear it down on
disconnect or scope removal. Tokens are recipient-bound, revision-sensitive,
non-persistent capabilities; never decode them, share them, or store them as
canonical ids. See [`discovery.md`](discovery.md) for the full authoring and
resync flow.

## 9. Presentation is intentionally downstream

The provided UI is not another authority. It is a replaceable layer built from:

- `InventoryPresentationModel`, which stores accepted snapshots, local
  selection/focus, pending intent, and temporary feedback as four separate
  layers;
- `InventoryInteractionController`, which turns pointer, keyboard, gamepad,
  drag/drop, context, and split interactions into command-sink calls;
- `InventoryRendererRegistry`, which selects a renderer for each layout; and
- spatial-grid, named-slot, ordered-list, discovery, two-pane, card, tooltip,
  modal, drag-ghost, and feedback controls.

The presentation model never holds an authority or replica reference. A host
feeds it snapshots and receipts. For an optimistic command, the host or
interaction controller calls `begin_intent()`, passes the returned value as
the real positive `command_id`, then calls `apply_result()` when the
authoritative receipt arrives. Optimistic ghosts and feedback live only in
the model; they never change the stored snapshot.

Display names, descriptions, categories, and icons are also presentation
data. Resolve them with `item_presentation_resolver` or your own catalog; do
not put localized display text into authority identifiers or mutable state.

Optional Common UI and Gameplay Abilities integrations depend one-way on this
addon. The base inventory system does not import either package, so it can be
used headlessly or with entirely custom controls.

## 10. Lifecycle and persistence

A safe application lifecycle is:

1. create and seal one catalog;
2. create an authority and assign the sealed catalog before any runtime;
3. choose `ROLE_OFFLINE_AUTHORITY` or `ROLE_SERVER_AUTHORITY` before the
   transaction pipeline is built;
4. create or restore inventories;
5. create gateway sessions and replicas only after compatibility admission;
6. persist owner records at game-defined checkpoints; and
7. revoke sessions/recipients and unload inventories when their ownership
   scope ends.

The catalog is fixed once an authority has built its pipeline. Treat the role
as startup configuration: it is labeling-only for direct authority behavior,
but a live gateway admits work only while its authority reports
`ROLE_SERVER_AUTHORITY`. Choose it before wiring the gateway and do not change
it while sessions are active.
Every public class is main-thread-only; move file/network/compression work
off-thread only after obtaining plain bytes, and return to the main thread
before calling the façade again.

`make_persistence_record()` creates a bounded owner record. Your game still
owns save slots, encryption, compression, account ownership, migration policy,
and storage durability. `apply_persistence_record()` validates compatibility,
rebuilds a candidate runtime, audits it, and installs it only on success.

By default, restoring over a live inventory id is rejected. Explicit
`replace_existing == true` creates a new runtime generation: inventory-scoped
command replay, reservation, discovery, observer-stream, and cached-delta
state are invalidated around the replacement. Clients must discard a same-id
mirror from the previous generation and bootstrap again.

`unload_inventory()` synchronously clears the canonical runtime and its scoped
support state before emitting `inventory_unloaded`. It does not own or free
remote replica nodes; the game/network bridge must dispose those mirrors.
Lifecycle replacement/unload from inside an authority signal is rejected to
avoid invalidating an in-flight notification.

## 11. Limits and failures are part of the contract

All identifiers, collections, payloads, queues, and network-facing retained
state are bounded. Decoders check bounds before allocating and fail closed on
unknown tags, truncation, trailing bytes, overflow, or incompatible versions.

Common current hard bounds include:

| Area | Bound |
|---|---:|
| Entries in any one catalog identifier registry | 4,096 |
| Items / containers / references in one default profile | 4,096 / 512 / 256 |
| Maximum nesting depth | 16 |
| Mutable components per item | 32 |
| Inventories in one transaction | 16 |
| Retained prepared-quantity reservations / lines per reservation | 256 / 64 |
| Stack quantity | 1,000,000 |
| Command / delta / canonical snapshot bytes | 4 KiB / 256 KiB / 1 MiB |
| Pending reentrant transactions | 64 |
| Gateway sessions | 1,024 |
| Gateway replay entries per session / retained replay bytes globally | 256 / 4 MiB |
| Default gateway command / resync rates | 32 per second / 16 per minute |

Profiles may lower their runtime aggregate limits but cannot raise them past
the compiled hard limits. Containers add their own lower capacity, layout,
filter, and access constraints. Discovery and observer streams have additional
recipient and byte budgets documented in [`discovery.md`](discovery.md#limits)
and [`api.md`](api.md#inventorynetworkgateway).

Every structured status has:

```text
{"code": int, "diagnostic": int, "detail": int64, "ok": bool}
```

The status code is the broad class—invalid argument, not found, limit,
revision, permission, role, invariant, rejected, or snapshot required. The
diagnostic identifies the precise reason; `detail` carries bounded numeric
context when applicable.

Useful recovery rules are:

| Failure | Correct response |
|---|---|
| Catalog not sealed or definition unknown | Fix bootstrap/authoring; do not retry the same runtime command. |
| Placement, filter, access, mass, count, stack, or nesting rejection | Keep the current snapshot and present the diagnostic; state is unchanged. |
| Revision mismatch | Replace stale UI state from a current snapshot, then let the user retry as new intent. |
| Replica snapshot required | Stop applying deltas, request a full baseline, and apply it atomically. |
| Session/hello/grant/policy rejection | Fix authenticated gateway state; never bypass it by calling remote authority methods directly. |
| Payload or retained-state limit | Reduce/bound the request or release scoped state; do not retry an identical oversize payload. |

The complete status and diagnostic lookup is in
[`troubleshooting.md`](troubleshooting.md).

## 12. Minimal offline example

This example builds one list inventory, inserts a stack, and reads the new
immutable snapshot. It intentionally resolves the runtime container id from
the initial snapshot instead of confusing it with the container definition
identifier.

```gdscript
extends Node

var authority: InventoryAuthority


func _ready() -> void:
    var ration := InventoryItemDefinition.new()
    ration.identifier = &"game.item.ration"
    ration.max_stack = 10
    ration.unit_mass_mg = 150

    var constraints := InventoryContainerConstraints.new()
    constraints.allow_stack_split = true

    var pouch := InventoryContainerDefinition.new()
    pouch.identifier = &"game.container.pouch"
    pouch.layout_kind = InventoryContainerDefinition.LAYOUT_ORDERED_LIST
    pouch.ordered_list_max_entries = 20
    pouch.constraints = constraints
    pouch.enabled_features = PackedStringArray([
        "inventory.feature.ordered_list",
        "inventory.feature.stacking",
    ])

    var profile := InventoryProfileDefinition.new()
    profile.identifier = &"game.profile.simple"
    profile.root_containers = PackedStringArray([pouch.identifier])
    profile.enabled_features = pouch.enabled_features

    var authored := InventoryCatalogResource.new()
    authored.items = [ration]
    authored.containers = [pouch]
    authored.profiles = [profile]

    var catalog := InventoryCatalog.new()
    var builtins: Dictionary = catalog.register_builtin_definitions()
    assert(int(builtins["status_code"]) == InventoryCatalog.STATUS_OK, str(builtins))
    for finding in catalog.register_catalog_resource(authored):
        assert(int(finding["status_code"]) == InventoryCatalog.STATUS_OK, str(finding))
    var sealed: Dictionary = catalog.seal()
    assert(int(sealed["status_code"]) == InventoryCatalog.STATUS_OK, str(sealed))

    authority = InventoryAuthority.new()
    authority.set_catalog(catalog)
    add_child(authority)

    var inventory_id := authority.create_inventory("game.profile.simple")
    assert(inventory_id > 0, str(authority.get_last_status()))

    var initial := authority.snapshot(inventory_id)
    assert(initial != null)
    var root_container_id := int(initial.get_containers()[0]["id"])

    var receipt := authority.insert_item(
        inventory_id,
        "game.item.ration",
        3,
        {
            "kind": "list",
            "container": root_container_id,
            "ordinal": 0,
        }
    )
    assert(bool(receipt["accepted"]), str(receipt["status"]))

    var current := authority.snapshot(inventory_id)
    assert(current.get_revision() == 1)
    var item: Dictionary = current.get_items()[0]
    print("%s x%d" % [item["item_definition_identifier"], item["quantity"]])
```

For a real project, save the authored resources as `.tres` assets, register a
catalog resource during bootstrap, and keep the authority under a stable
game-owned node. The runtime flow remains the same.

## 13. Common mistakes

- Using `game.container.pouch` in a location dictionary. Locations require the
  runtime container instance id returned by a snapshot.
- Editing an authoring resource after `seal()` and expecting existing
  inventories to change. Registration copied it; rebuild a new compatible
  catalog/session deliberately.
- Treating a successful `fits()` preview as a reservation. Another accepted
  command can change the revision before submission.
- Reusing one explicit command id for different intent.
- Playing accepted feedback again for a `replayed` receipt.
- Treating a `queued` reentrant marker as a committed result.
- Mutating a snapshot item dictionary and expecting authority state to change.
- Sending raw `delta_ready` bytes to every client instead of using the
  gateway's per-session, per-inventory grant-scoped egress.
- Sending canonical owner snapshot bytes to observers. Use the separate
  observer protocol and replica type.
- Trusting actor, peer, visibility, or inventory scope supplied inside a
  client packet.
- Forgetting to tear down discovery recipients or replicas when a session or
  inventory generation ends.

## Where to go next

- [`authoring.md`](authoring.md): exact resource fields, identifier grammar,
  feature derivation, and editor validation.
- [`api.md`](api.md): transactional commands, gateway, replica/snapshot, and
  non-discovery authoring reference.
- [`integration.md`](integration.md): authority ownership, main-thread rules,
  gateway setup, persistence, owner/observer transport, and resync examples.
- [`presentation.md`](presentation.md): snapshot model, interaction controller,
  renderer registry, controls, and optional adapters.
- [`discovery.md`](discovery.md): staged disclosure authoring and runtime flow.
- [`generated/`](generated/): exhaustive structural list of native bound
  classes, methods, signals, properties, and constants.
- [`troubleshooting.md`](troubleshooting.md): exact status/diagnostic recovery.
- [`verification.md`](verification.md): build and test commands.
