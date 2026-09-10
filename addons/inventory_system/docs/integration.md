# Integration: Ownership, Lifetime, Authority, Persistence, and Networking

How a game wires the Godot façade end to end: a full quickstart from an
authored catalog to a UI reading a snapshot, who owns what and for how long,
the single-threaded contract, the authority/replica boundary (including what
a game must do itself because this façade slice does not do it), how to
persist and reload an inventory, and a complete network-integration
walkthrough with the resync loop.

## Quickstart: catalog resource → seal → authority → commands → snapshot → UI reads

This is the complete pipeline. See [`authoring.md`](authoring.md) for how the
catalog resource itself is built and what each field means.

```gdscript
# 1. Build and seal a catalog (authoring.md's quickstart covers this step in
#    full; abbreviated here).
var catalog := InventoryCatalog.new()
catalog.register_builtin_definitions()
catalog.register_catalog_resource(my_catalog_resource)
catalog.seal()

# 2. Stand up an authority. OFFLINE_AUTHORITY is the default role -- see
#    "Authority boundary" below for what ROLE_SERVER_AUTHORITY does (and does
#    not) change.
var authority := InventoryAuthority.new()
authority.set_catalog(catalog)
add_child(authority)

# 3. Create an inventory from a sealed profile.
var inventory_id := authority.create_inventory("game.profile.character")

# 4. Submit commands. Every method returns the command-result Dictionary
#    documented in api.md; `transaction_committed` fires the same Dictionary
#    as a signal for any listener that does not hold the direct call site
#    (a UI presentation layer, typically).
var result := authority.insert_item(inventory_id, "game.item.ration", 3,
        {"kind": "list", "container": root_container_id, "ordinal": 0})
if not result["accepted"]:
    push_warning("insert rejected: %s" % str(result["status"]))

# 5. Read a snapshot. This is what a UI actually renders -- an immutable DTO,
#    never a live reference into authority storage.
var snapshot := authority.snapshot(inventory_id)
for item in snapshot.get_items():
    # item: {id, item_definition_identifier, quantity, location, ...}
    _render_item_card(item)
```

A UI layer should hold ONLY snapshots (and, for optimistic feedback, its own
pending-intent state — never a mutated copy of canonical data). Re-fetch a
fresh `snapshot()` after every accepted `transaction_committed`, or apply the
signal's own result Dictionary incrementally if the presentation layer wants
finer-grained feedback (the `events` array names exactly what changed).

## Ownership and lifetime

| Object | Owner | Lifetime |
|---|---|---|
| `inv::DefinitionCatalog` (native) | Exactly one `InventoryCatalog` `RefCounted` | For the life of that `RefCounted`. Never exposed by pointer/reference — `InventoryCatalog.native_catalog()` is a C++-only accessor for `InventoryAuthority`/`InventoryReplicaNode` in the SAME module, not ClassDB-bound. |
| Every `inv::InventoryRuntime` (canonical, mutable inventory state) | Exactly one `InventoryAuthority` `Node`, keyed by inventory id | For the life of that `Node`, until `unload_inventory(id)`, or until an explicit `apply_persistence_record(bytes, true)` replaces one keyed entry. **This is the only place canonical, mutable inventory storage lives** — nothing else in this addon owns it, and nothing hands out a mutable reference to it. |
| `inv::protocol::InventoryReplica` (mirrored, read-only inventory state) | Exactly one `InventoryReplicaNode` `Node` | For the life of that `Node`. Represents exactly ONE remote inventory. |
| `inv::protocol::InventoryObserverReplica` (recipient-scoped projected value state) | Exactly one `InventoryObserverReplicaNode` `Node` | For the life of that `Node` and one immutable `(session, actor, inventory, visibility)` stream tuple. It owns no canonical runtime, allocator, restore path, or mutation primitive; dispose it when the authority revokes/tears down the recipient or unloads the inventory. |
| `InventoryNetworkGateway` (authenticated server façade) | The game/server scene that created it | For the server authority generation. It owns session/epoch bindings, command and replication grants, replay journals, and recipient stream policy; it owns neither transport sockets nor canonical inventory state. |
| `inv::InventorySnapshot` (immutable value copy) | Exactly one `InventorySnapshotResource` `Resource` | A plain owned value, deep-copied at `snapshot()` time. Copying or mutating an `InventorySnapshotResource` (which has no mutating methods exposed anyway) can never alias or affect `InventoryRuntime`'s canonical storage. |
| Authoring `Resource` instances (`InventoryItemDefinition` etc.) | The game/editor code that created them | Registration COPIES their field values into the native catalog; the addon never retains a reference to the authoring Resource itself. Mutating one after `seal()` has zero effect on the sealed catalog (7.2's isolation guarantee — see `authoring.md`). |

`InventoryCatalog` is `RefCounted`, not `Node`: a sealed catalog has no
per-frame behavior and no scene-tree owner to guard. `InventoryAuthority` and
`InventoryReplicaNode` are `Node`s because they DO need a scene-tree lifetime
to guard their post-commit signal delivery (see the next section) and, in a
networked game, a natural place to live under a `MultiplayerAPI` branch or a
game-owned bridge node.

### Checked lifetime identity (post-commit signal safety)

Both `InventoryAuthority` and `InventoryReplicaNode` register a native
observer/listener callback with their underlying pipeline/replica object
that ultimately calls `emit_signal()`. Neither callback captures `this`
directly — each captures only its owning Node's `ObjectID` and re-resolves
it through `ObjectDB::get_instance()` immediately before touching `this`, so
a reentrant or delayed notification arriving after (or during) the Node's own
teardown is a silent no-op rather than a dangling-pointer access. This
mirrors `gameplay_abilities`'
`GameplayAbilityWorldCoordinator::register_component()`/
`prune_freed_components()` precedent exactly. As a game author you do not
need to do anything to get this safety — it holds regardless of when you
`queue_free()` an `InventoryAuthority`/`InventoryReplicaNode`, including
from inside one of its own signal handlers.

## Single-threaded / main-thread contract

**Every method on every class this addon exposes must be called from the
main thread.** `inv::InventoryTransactionPipeline`, `inv::InventoryRuntime`,
and every other core/protocol type are plain, non-thread-safe C++ objects
with no internal locking — the entire native core is deliberately
single-threaded (matches `gameplay_abilities`' own core determinism
discipline: a single canonical mutation order, no concurrent writers). There
is no async/threaded variant of `InventoryAuthority.move_item()` or any other
command method, and none of the Dictionary/PackedByteArray/Resource values
this addon hands back are safe to read or write from a non-main thread while
the owning `InventoryAuthority`/`InventoryReplicaNode` might also be mutating
state on the main thread.

If a game needs off-main-thread work (network I/O, file persistence,
compression), do that work on the bytes this façade already produced/
consumes (`snapshot_envelope_bytes()`, `make_persistence_record()`,
`last_delta_batch_bytes()`) — those are server-local, plain `PackedByteArray`
values safe to hand to a worker thread once returned — and marshal the RESULT
back to the main thread before calling anything back into `InventoryAuthority`/
`InventoryReplicaNode`.

## Authority boundary

### Roles are labeling-only in V1

`InventoryAuthority.role` (`ROLE_OFFLINE_AUTHORITY` / `ROLE_SERVER_AUTHORITY`)
is an explicit, labeling-only property. The two roles differ in **nothing**
this façade slice implements functionally — both are full canonical
authority over their owned runtimes, exactly like the core's own
`inv::PermissionProvider`/transaction pipeline make no OFFLINE-vs-SERVER
distinction internally (`inventory_authority.h`'s own class comment). Setting
`role = ROLE_SERVER_AUTHORITY` does not, by itself, add any network
enforcement, session gating, or peer-ownership check — a game that needs
those must build them in its own bridge.

### Structural replica safety IS enforced

The half of role safety that IS structurally enforced — "a remote replica
cannot invoke authority-only mutation" — is enforced by `InventoryReplicaNode`
simply never DECLARING a mutation method at all, not by a runtime role check
on `InventoryAuthority`. There is no method to forget to guard, and no way to
reach one through `InventoryReplicaNode`'s public surface, its ClassDB
binding, or the C++ `inv::protocol::InventoryReplica` type it wraps (which
has no `InventoryTransactionPipeline` member at all). This is verified by
`tests/integration/inventory_probe.gd` and the contract suite both asserting
`not replica.has_method("move_item")` etc. for every one of `InventoryAuthority`'s
19 mutating command methods, including the transactional
`set_item_component()` and `remove_item_component()` component-state commands.

### What a game must own: direct policy and transport

`InventoryAuthority` hard-codes `inv::AllowAllPermissionProvider` — an
always-allow implementation of the core's `inv::PermissionProvider`
interface (`native/core/inv_transaction.h`). **This façade slice exposes no
game-owned permission-policy seam at all**: there is no bound method to
install a custom `PermissionProvider`, and the interface itself has no
ClassDB registration (it is a pure C++ virtual interface, unreachable from
GDScript or C#). Per design.md's "Authority, protocol, and persistence":

> The addon defines authority-ready value contracts but does not create a
> multiplayer peer or choose a transport. A game-owned bridge authenticates
> a sender, resolves its allowed inventory scopes, checks world and gameplay
> policy, and submits intent to the authoritative inventory façade.

For direct `InventoryAuthority` calls, **a game's own bridge must still
authenticate the actor and check world/gameplay policy before invoking the
typed command method**. The `actor` parameter is a plain, game-scoped opaque
identity that the core does not interpret as permission. For remote command
bytes in API 0.4.0, use `InventoryNetworkGateway`: it supplies the
game-owned `world_policy` Callable as a mandatory policy seam and fails
closed when it is missing or rejects the post-revision context. The gateway
does not replace transport authentication; the game transport must obtain
the trusted peer (Godot RPC handlers should use `get_remote_sender_id()`),
then pass that context explicitly.

### Authenticated `InventoryNetworkGateway` (API 0.4.0)

`InventoryNetworkGateway` is a server/game-owned, transport-neutral `Node`.
It deliberately owns no `MultiplayerPeer`, socket, RPC method, thread, or
timer. A game-owned transport invokes it synchronously after authenticating a
connection. `InventoryAuthority` command bytes are raw protocol bytes, not
RPC messages; packet fields cannot select their peer, actor, inventory grant,
or observer visibility. Direct `snapshot_*()`/`delta_*()` methods are
grant-scoped trusted server egress helpers only.

The minimum server setup is:

```gdscript
var gateway := InventoryNetworkGateway.new()
gateway.authority_path = authority.get_path()
gateway.configure(server_authority_epoch, 60)
gateway.world_policy = func(context: Dictionary) -> bool:
    # Check game ownership/zone/rules from your own server state.
    var touched: PackedInt64Array = context["touched_inventories"]
    return touched.size() > 0 and _world_allows_inventory(context["actor"], touched[0])
add_child(gateway)

# After authenticating the connection in the game transport:
gateway.begin_session(peer_id, session_id, actor_id, connection_epoch)
gateway.grant_command_inventory(session_id, inventory_id)
gateway.set_command_allowlist(session_id,
        InventoryNetworkGateway.COMMAND_MASK_MOVE_ITEM |
        InventoryNetworkGateway.COMMAND_MASK_ROTATE_ITEM)
gateway.grant_owner_replication(session_id, inventory_id)
gateway.accept_session_hello(peer_id, session_id, connection_epoch,
        client_hello_bytes)
```

The installed `world_policy` `Callable` is trusted server code. Keep its
evaluation pure with respect to `InventoryAuthority`: it must not submit
typed or raw commands, invoke lifecycle operations such as unload or
persistence replacement, mutate quantity reservations, perform discovery
mutations, or make other authority mutations, and it must not perform
external side effects. The gateway blocks recursive gateway entry, but it
cannot generally roll back arbitrary side effects performed by trusted
callback code.

The engine-free/custom `CommandExecutor` callback is synchronous and
immediate. It must not enqueue work or perform any side effects when it
returns a `queued` result; the gateway rejects queued outcomes because they
cannot produce one authoritative reply in the current admission call.

The call order and identity rules are strict:

1. The game binds `peer_id` from its trusted transport context, never from
   packet bytes. `begin_session()` binds `(peer, session, actor,
   connection_epoch)`; `accept_session_hello()` must then admit exact
   `SessionHello` bytes for the configured positive `authority_epoch` and
   `tick_rate` before command or resync admission.
   Fresh logical session ids must be strictly greater than all prior fresh
   ids within one authority epoch. A reconnect reuses the same logical id and
   actor/authority epoch with a strictly higher `connection_epoch`; it may
   migrate to a different authenticated peer, moving grants, replay/sequence
   state, and both rate buckets while rejecting the old peer/old epoch. A
   higher authority epoch starts a new id domain only after all live sessions
   are gone; rollback or live rotation is rejected.
2. Command permissions are default-deny. A remote command needs both an
   allowlisted class and an exact command-inventory grant. The six hard
   authority-only classes are `INSERT_ITEM`, `REMOVE_ITEM`, `DROP_ITEM`,
   `SETTLE_INVENTORY`, `SET_ITEM_COMPONENT`, and `REMOVE_ITEM_COMPONENT`;
   gateway ingress rejects them even if their mask bit is present. A trusted
   server/game path may invoke those authority operations directly after its
   own policy check. A nonzero mask alone never bypasses an inventory grant.
3. The envelope's `header.command_id` is a client-local sequence and the
   `header.actor` is an exact echo only. After admission, both are replaced
   with server canonical identity before authority execution. Exact matching
   command id plus complete bytes returns a normalized
   `DUPLICATE_RESULT_REPLAY` receipt (`replayed=true`, no events, and no
   delta/side-effect bytes) without a second execution. Different bytes
   conflict; evicted/lower entries and in-flight or re-entrant submissions
   fail closed. Retained request and receipt bytes, including in-flight
   reservations, count against the one global 4 MiB replay budget.
4. The authenticated command-ingress token bucket is consumed by both
   command bytes and SessionHello attempts, before hello readiness,
   size/decode, or compatibility. Rate accounting, bounded byte checks,
   hello/epoch/grant checks, and command decoding happen before execution;
   malformed and oversized command or hello bytes consume that same bucket.
   Resync has a separate bucket. Revision is read before the mandatory world
   policy callback. No policy callback means deny; there is no implicit allow.

The default contract bounds 1024 sessions, 256 command grants and 64
engine-free observer grants per session, 256 replay entries per session, and
4 MiB of retained replay bytes globally (including in-flight reservations),
plus 32 commands/second and 16 resync requests/minute (at 60 ticks per
second), with bounded observer view, stream, and generation ledgers. The
Godot façade additionally caps the combined owner plus observer/redacted
replication map at `MAX_REPLICATION_GRANTS_PER_SESSION = 256`; this does not
raise the engine-free observer grant cap. The
limits are negotiated/validated with the protocol contract; do not raise
them in a transport wrapper.

Command access and replication access are separate grants. Owner replication
is canonical owner egress; observer/redacted replication is a separate
recipient-safe `inventory-observer-v1` full-replacement stream. Push
snapshot/delta egress requires `session_ready(session)` in addition to the
stored replication grant, so no state is sent before exact hello admission.
The gateway looks up observer visibility from its stored grant, so a
`generation=0`/`sequence=0` resync is the only bootstrap exception and
packet content can never widen scope. Revoke/teardown invalidates the live
grant immediately; cached replay/stream state cannot restore permission.

For a Godot transport callback, the intended shape is:

```gdscript
func _on_inventory_command(packet: PackedByteArray) -> void:
    var peer_id := multiplayer.get_remote_sender_id()
    var result := gateway.submit_command_bytes(peer_id, session_id,
            connection_epoch, packet, server_tick)
    _send_result_or_egress(peer_id, result)
```

The exact same trusted peer/session/connection tuple is required for
`resync_result()`/`resync_bytes()`. Observer requests carry no visibility
authority. `snapshot_result()`/`snapshot_bytes()` and
`delta_result()`/`delta_bytes()` should be called only by server code after
the stored replication grant and completed `session_ready()`/exact hello are
checked, and their output is forwarded by the game transport; they are not
remote-call entry points. The same completed-hello requirement applies to
`resync_result()`/`resync_bytes()` before any snapshot response is sent.

### Stale-revision rejection is not reachable through this façade in V1

`InventoryAuthority`'s every typed command method computes its
`CommandHeader`'s expected revision from THIS façade's own current runtime
state, synchronously, immediately before submission — there is no
explicit-stale-revision override anywhere in the bound API. This means
`StatusCode.STATUS_REVISION_MISMATCH` (60) and its accompanying
`conflicting_inventory`/`authoritative_revision` result fields cannot be
produced by ANY sequence of calls through this Godot façade — not a gap in
test coverage, but a structural property of how `make_header()` is
implemented. It IS exercised directly against `inv::InventoryTransactionPipeline`
in `native/tests/inv_test_transactions.cpp`. See the contract suite's
`_test_rejection_contract()` for the executable documentation of this limit
and what it verifies instead (the result Dictionary's shape contract).

### Snapshot visibility and the observer boundary

`InventoryAuthority.snapshot()` accepts a visibility parameter for local value
inspection and applies the corresponding projection to the returned Resource,
but that Resource is never a safe canonical restore source for a non-owner.
`snapshot_envelope_bytes()` is stricter: it is the canonical owner transport
and rejects non-owner visibility because its envelope type carries canonical
ids and allocator metadata. Do not send that envelope to an untrusted peer.

For a real observer stream, use
`InventoryAuthority.observer_snapshot_envelope_bytes()` and
`observer_delta_bytes()` with `InventoryObserverReplicaNode`. This path uses a
separate `inventory-observer-v1` / version-1 envelope, applies policy before
encoding, and stores only a structurally separate projected value on the
client. `VISIBILITY_REDACTED` exposes aggregate-only container shells and
policy-approved counts, never hidden item rows or their identifiers,
definitions, quantities, locations, components, or provided-container links.
`VISIBILITY_OBSERVER` may retain detail for policy-authorized containers and
uses aggregate shells for redacted regions. Observer handles are recipient-
local opaque values, not canonical ids.

The observer authority methods are local, non-RPC primitives. Recipient
registration establishes lifecycle state only; it does not authenticate the
transport principal or authorize access. A game-owned gateway (Task 4.6) must
authenticate and authorize the exact session, actor, inventory, and visibility
before invoking these methods or transmitting their bytes. SessionHello must
negotiate feature bit `1 << 9` (`OBSERVER_REPLICATION`) before any observer
packet is accepted. For Task 4.6 client egress, these authority methods remain
server-local generation helpers; the transport sends only the gateway's
per-session/per-inventory, grant- and hello-filtered bytes.

## Persistence

`InventoryAuthority` exposes a symmetric make/apply pair:

```gdscript
var record_bytes := authority.make_persistence_record(inventory_id)
# ... store record_bytes with your own save system (slot, encryption,
# compression, and account ownership are all game-owned; see
# compatibility.md's persistence-compatibility pointer) ...

# Later, on a fresh authority (or the same one, after a restart):
var fresh_authority := InventoryAuthority.new()
fresh_authority.set_catalog(catalog) # same sealed catalog (or a compatible one)
add_child(fresh_authority)
var load_result := fresh_authority.apply_persistence_record(record_bytes)
if load_result["ok"]:
    var loaded_inventory_id: int = load_result["inventory_id"] # NOT necessarily the id you started with -- it is the id ENCODED in the record
```

`apply_persistence_record()` installs the decoded inventory keyed by the
record's OWN encoded inventory id (which round-trips through
`make_persistence_record()` unchanged) and advances the authority's monotonic
inventory-id allocator past that id. A live-id collision fails atomically by
default; an intentional live replacement must call
`apply_persistence_record(record_bytes, true)`. A successful live replacement
establishes a new runtime generation. The authority removes only bounded
idempotency-journal entries whose accepted result touched that inventory
(including a multi-inventory command that names it), so reusing an old command
id runs normal validation against the replacement instead of returning a stale
success. The authority emits
`inventory_generation_changing(inventory_id)` before the new same-id runtime is
made visible; the bound gateway invalidates affected grants, replay state, and
cached egress during that lifecycle edge. Bridges must invalidate same-id
replicas before forwarding new snapshots/deltas. Entries for unrelated
inventories keep their FIFO order, and
the transaction pipeline itself remains alive with its observers and any queued
reentrant submissions intact. A persistence round trip (make → fresh authority
→ load) reproduces byte-identical
`canonical_bytes()`/`hash()`, verified by the contract suite's
`_test_persistence()`.

To retire an inventory without replacing it, call
`authority.unload_inventory(inventory_id)`. The authority clears the same
inventory-scoped ephemeral/protocol state before erasing the runtime, then
emits `inventory_unloaded(inventory_id)`. A matching `InventoryReplicaNode` is
not owned by the authority and is not reset automatically: the game/network
bridge must dispose it after forwarding this lifecycle notification. Unload,
restore, and replacement are rejected with
`AUTHORITY_LIFECYCLE_BUSY` if called synchronously from any authority signal
callback, preventing reentrant runtime erasure or resurrection.

## Network integration walkthrough: authority bytes → transport → replica

This addon never creates a `MultiplayerPeer` or chooses a transport — that
is entirely game-owned, exactly like `gameplay_abilities`'
`GameplayAbilityNetworkBridge` documents for its own domain. The façade's
job is to produce and consume the bytes; a game's own bridge Node moves them.
For API 0.4.0 remote command ingress, that bridge should call
`InventoryNetworkGateway.submit_command_bytes()` with the trusted peer from
`get_remote_sender_id()` (never a packet field). The direct authority calls
shown below are trusted server-local primitives; they are not RPC handlers and
must not be exposed to an untrusted client. Client egress goes through the
gateway, which applies the session, completed-hello, grant, visibility, and
per-inventory filters.

```text
   [ InventoryAuthority ] --(server-local signal/bytes only)-->
   [ InventoryNetworkGateway ] --(per session + inventory, filtered)--> [ Replica ]
                                                                    (remote client)

   delta_ready / last_delta_batch_bytes()  --local trigger-->
   gateway.snapshot_bytes() / delta_bytes() / resync_bytes() --packet--> apply_*()
```

1. **Initial sync (late join or first connect).** The server/offline host
   binds the peer/session/actor/epochs, completes the exact `SessionHello`,
   and grants the appropriate owner or observer scope. It then calls the
   gateway's `snapshot_bytes(session_id, inventory_id)` and sends only that
   grant-scoped result over its own transport. For non-owner recipients, the
   gateway returns the dedicated observer flow below. The client's bridge
   calls `replica.apply_snapshot_bytes(bytes)`. This is also the ONLY event
   `InventoryReplicaNode` fires for a snapshot — `snapshot_replaced` — so a
   client UI can treat "first snapshot" and "later resync" identically.

2. **Steady-state deltas.** `authority.delta_ready` and
   `authority.last_delta_batch_bytes()` are server-local integration signals
   and raw multi-inventory bytes. Never forward them as a client broadcast.
   Use the signal only to schedule gateway calls for each authorized
   `(session, inventory)` pair: `gateway.delta_bytes(session_id, inventory_id,
   predecessor_revision)` for owner egress, or the gateway's stored observer
   scope for observer egress. Each call requires completed hello and an exact
   replication grant; the resulting per-inventory bytes are then sent to that
   client. A multi-inventory transaction therefore produces separate
   permission-filtered egress decisions, not one shared raw batch. For OWNER
   `DeltaBatch` egress, the gateway always clears `source_command_id` to `0`;
   the server-local authority batch retains the authority-global id, which
   must not be used to correlate other touched inventories or principals.

3. **The resync loop.** If a client's bridge ever calls
   `replica.apply_delta_bytes()` with a delta whose `predecessor_revision`
   doesn't match the replica's own `get_last_applied_revision()` (a dropped
   packet, an out-of-order delivery, or a replica that just joined mid-
   stream), the replica detects the gap, sets `needs_resync() == true`, and
   fires `resync_needed(inventory_id, last_applied_revision)`:

   ```gdscript
   replica.resync_needed.connect(func(inventory_id: int, last_applied_revision: int) -> void:
       var request_bytes := replica.resync_request_bytes()
       _send_to_server(request_bytes) # game-owned transport call
       # The server's gateway requires completed SessionHello and the stored
       # owner/observer grant, then returns gateway.resync_bytes(...).
   ```

   Once the fresh snapshot arrives, the SAME `apply_snapshot_bytes()` call
   from step 1 heals the replica: `needs_resync()` clears,
   `get_last_applied_revision()` becomes the new snapshot's revision, and
   `snapshot_replaced` fires again. A delta that arrives late and duplicates
   one the replica already covered (via the healing snapshot or an earlier
   delta) is a harmless, non-fatal no-op — `needs_resync()` stays `false`
   and no signal fires again for it. See `tests/inventory_system/contract/
   inv_contract_main.gd`'s `_test_deltas_and_resync()` for the complete,
   executable gap → `needs_resync` → resync-request → snapshot-heal →
   duplicate-delta-no-op cycle, and [`api.md`](api.md)'s `apply_delta()`
   checked-order table for the exact 5-case decision logic.

4. **Session compatibility.** Before any of the above, a game's bridge
   should exchange `authority.session_hello_bytes()` and validate
   compatibility (see [`compatibility.md`](compatibility.md)) — a manifest-
   fingerprint or protocol-version mismatch should be treated as fatal for
   that session, not silently ignored. The gateway rejects direct snapshot,
   delta, and resync egress until this exact hello has completed for the
   current authority and connection epochs.

### Recipient-safe observer flow

Use this flow when the remote peer is allowed to inspect only a policy-scoped
view. It is deliberately not a visibility mode on the canonical flow:

```text
   [ InventoryNetworkGateway ]                    [ InventoryObserverReplicaNode ]
   (authenticated server egress)                  (one exact recipient stream)

   gateway.snapshot_bytes(session, inventory) ---> apply_snapshot_bytes(bytes)
   gateway.delta_bytes(session, inventory, seq) -> apply_delta_bytes(bytes)
   gateway.resync_bytes(peer, session, ...) <---- resync_request_bytes()
```

1. The game gateway authenticates the transport principal, checks the exact
   `(session_id, actor_id, inventory_id, visibility)` policy, completes the
   exact hello, grants the observer scope through the gateway, and configures
   the observer node with that same tuple. Registration and the authority
   observer methods are local lifecycle primitives, not RPC handlers and not
   authorization. Do not derive the tuple from an unauthenticated packet.

   ```gdscript
   # After the gateway has authenticated/authorized this exact tuple:
   gateway.grant_observer_replication(session_id, inventory_id,
           InventoryNetworkGateway.VISIBILITY_REDACTED)
   observer.set_catalog(catalog)
   observer.configure_stream(session_id, actor_id, inventory_id,
           InventorySnapshotResource.VISIBILITY_REDACTED)
   var baseline := gateway.snapshot_bytes(session_id, inventory_id)
   observer.apply_snapshot_bytes(baseline)
   ```

2. Forward only the dedicated observer bytes. The baseline and every delta
   are full replacement views with an independent recipient-visible sequence;
   they are not canonical `DeltaBatch` operations. A hidden-only authority
   mutation yields an empty gateway `delta_bytes()` result and does not advance
   the observer sequence. A visible mutation yields a successor view whose
   predecessor must equal `observer.get_last_applied_sequence()`.

3. If the observer node receives a gap, wrong generation, wrong tuple, or
   invalid successor, it leaves the last safe view untouched, latches
   `needs_resync()`, and emits `resync_needed` once. After the stream is
   configured but before a baseline exists, `resync_request_bytes()` is a
   valid bootstrap request with `generation=0` and
   `last_applied_sequence=0`. `ObserverResyncRequest` intentionally omits
   visibility: packet content never grants or changes scope. The Task 4.6
   gateway resolves visibility from its authenticated configured
   `(recipient, inventory)` stream policy/cache, including this `0/0` case
   where no cached view exists, then sends a fresh observer baseline through
   `resync_bytes()`; this also requires the completed hello. After
   initialization the request carries the current positive generation and
   sequence. No canonical restore or hidden-state recovery is attempted.

4. Dispose the observer node when the authority revokes/tears down the
   recipient or unloads the inventory. The authority does not own or reset
   remote observer nodes. Keep the node's `view()` dictionary as the only
   client-facing state: its manifest fingerprint is a decimal `String`, and
   `REDACTED` streams expose aggregate-only shells/counts rather than hidden
   item rows or canonical handles.
