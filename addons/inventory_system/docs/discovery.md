# Staged container discovery

Staged discovery is an opt-in, authority-owned disclosure layer for containers
whose contents must not be visible immediately. It does not mutate canonical
inventory state: inventory revisions and hashes continue to describe item
ownership and placement, while a separate discovery revision describes what
one authenticated recipient has learned.

Containers without a discovery policy retain the historical instant-open
behavior and byte-compatible authoring/session records. A profile may contain
instant-open and staged roots together; see
[`examples/inventory/extraction_catalog.gd`](../../../examples/inventory/extraction_catalog.gd)'s
`build_catalog_resource_with_discovery()`.

## Disclosure states

| State | Recipient can see | Recipient can request |
|---|---|---|
| Unsearched | Authored safe shell label and opaque container token | Search |
| Searching | Shell, confirmed elapsed/duration, opaque token | Cancel |
| Indexed | Layout kind, dimensions/capacity, direct-item count, one opaque token per unrevealed item | Scan an entry |
| Scanning | Indexed metadata and confirmed entry progress | Cancel |
| Revealed | The revealed item through the ordinary projected snapshot/card path | Ordinary item actions allowed by the host |

Before indexing, the canonical container id, definition identifier, layout,
dimensions, count, items, locations, and descendants are absent. Indexing
reveals only the layout/count contract. An unknown entry never contains a
canonical item id, definition, footprint, location, traits, mutable
components, or provided-container links. Revealing a provider item can expose
its nested container as a new, independently unsearched shell; it does not
reveal that nested container's contents.

## Authoring

`InventoryDiscoveryPolicy` fields are copied and sealed with the catalog:

| Property | Default | Rule |
|---|---:|---|
| `identifier` | empty | Stable lower-case dotted identifier. |
| `schema_version` | `1` | Must match the supported authoring schema. |
| `container_search_instant` | `false` | When true, zero search duration is explicit and valid. |
| `container_search_duration_ms` | `1000` | Positive for non-instant search; at most 86,400,000 ms. |
| `item_scan_instant` | `false` | When true, zero scan duration is explicit and valid. |
| `item_scan_duration_ms` | `500` | Positive for non-instant scan; at most 86,400,000 ms. |
| `shell_label` | empty | Presentation-safe text only; never an authority identifier. |

Assign the policy identifier to
`InventoryContainerDefinition.discovery_policy_identifier`, add
`inventory.feature.discovery` to that container and its active profile, and
place the policy in `InventoryCatalogResource.discovery_policies`.
`register_catalog_resource()` automatically registers the optional discovery
feature before the first policy. It remains possible to register the feature
and policies explicitly through `register_discovery_definitions()` and
`register_discovery_policy()`.

```gdscript
var policy := InventoryDiscoveryPolicy.new()
policy.identifier = &"game.discovery.field_cache"
policy.container_search_duration_ms = 800
policy.item_scan_duration_ms = 300
policy.shell_label = "Sealed field cache"

var staged := InventoryContainerDefinition.new()
staged.identifier = &"game.container.field_cache"
staged.layout_kind = InventoryContainerDefinition.LAYOUT_SPATIAL_GRID
staged.grid_width = 4
staged.grid_height = 3
staged.discovery_policy_identifier = policy.identifier
staged.enabled_features = PackedStringArray([
    "inventory.feature.discovery",
    "inventory.feature.spatial_grid",
])

var profile := InventoryProfileDefinition.new()
profile.identifier = &"game.profile.loot"
profile.root_containers = PackedStringArray([staged.identifier])
profile.enabled_features = PackedStringArray([
    "inventory.feature.discovery",
    "inventory.feature.spatial_grid",
])

var resource := InventoryCatalogResource.new()
resource.discovery_policies = [policy]
resource.containers = [staged]
resource.profiles = [profile]
```

Leaving `discovery_policy_identifier` empty is the instant-open compatibility
path. Do not author a non-instant zero duration; the explicit instant flags
exist so zero is never ambiguous.

## Authority lifecycle

The game authenticates the transport/session first, then registers its opaque
positive session and actor ids:

```gdscript
authority.register_discovery_recipient(session_id, actor_id)
var view := authority.discovery_view(session_id, actor_id, inventory_id)
```

The untrusted intent surface is:

- `begin_container_search(session, actor, inventory, container_token,
  request_id=0, expected_inventory_revision=-1,
  expected_discovery_revision=-1)`
- `begin_item_scan(session, actor, inventory, entry_token, request_id=0,
  expected_inventory_revision=-1, expected_discovery_revision=-1)`
- `cancel_discovery(session, actor, inventory, request_id=0,
  expected_inventory_revision=-1, expected_discovery_revision=-1)`

Positive request ids are idempotency keys. Reusing one with the same payload
replays its result; reusing it for a different payload fails closed. Passing
both expected revisions protects an exact UI capture against canonical or
discovery changes. The convenience `-1` defaults use the authority's current
values and are appropriate only when the caller is not forwarding a
previously captured remote intent.

Only trusted offline/server code calls
`advance_discovery(session, actor, elapsed_ms)`. Each call accepts 1–60,000
integer milliseconds, one actor can own at most one active discovery task,
and completion occurs only when trusted accumulated time reaches the sealed
duration. There is deliberately no client-facing complete or reveal method.
Use the supplied offline and dedicated-server coordinators in
[`examples/inventory/`](../../../examples/inventory/) as the reference loops.
Game policy cancels an active task by calling `cancel_discovery()`; the
offline example exposes this as `cancel_for_game_policy()`.

Always destroy recipient state when authority changes:

- `revoke_discovery_inventory()` removes one inventory's learned state.
- `teardown_discovery_recipient()` removes one session/actor.
- `teardown_discovery_session()` removes every actor under a disconnected
  session.

Teardown destroys active tasks, idempotency records, issued tokens, and
learned contents. A reconnect is a new recipient scope and starts at
discovery revision zero with new tokens.

## Views, deltas, replicas, and protocol

`discovery_view()` returns an immutable
`InventoryDiscoverySnapshotResource` containing:

- inventory id, canonical inventory revision, and independent discovery
  revision;
- a redacted `InventorySnapshotResource` containing only instant-open and
  revealed canonical records;
- staged container/entry view Resources and one safe active-task view.

`discovery_delta()` carries explicit predecessor/successor pairs for both
revision axes. V1 deltas are complete replacement views, not op patches, so a
hidden identity cannot survive because a removal op was omitted. The byte
forms are `discovery_view_bytes()` and `discovery_delta_bytes()`.

`InventoryReplicaNode.apply_discovery_view_bytes()` installs a full
replacement; `apply_discovery_delta_bytes()` accepts only exact predecessor
pairs. On a gap it sets `discovery_needs_resync()` and emits
`discovery_resync_needed`; fetch and apply a new full view. A replica exposes
no begin, cancel, advance, complete, or reveal authority method.

Discovery has its own protocol version (`1`) and
`discovery_hello_bytes()`. It is negotiated only for participating
catalogs/profiles. The legacy `SessionHello` and non-discovery catalog
manifest remain byte-identical when discovery is absent. Intent, result,
view, and delta decoders are bounded and fail closed on unsupported versions,
unknown tags, truncation, trailing bytes, or collection/payload overflow.

## Presentation

`InventoryPresentationModel.apply_discovery_snapshot()` and
`apply_discovery_delta()` track recipient views separately from ordinary
network loading. They preserve exact pending intent tuples, apply state
precedence, mark stale-token/revision failures as discovery resync, recover
focus to a safe surviving target, and expose only eligible Search, Scan, or
Cancel actions.

`InventoryDiscoveryContainerControl` renders the state table above.
`InventoryTwoPaneView` discovers those controls from the model and routes
revealed items through `InventoryItemCard`. Unknown entries are separate
opaque-token buttons and structurally have no select, open, context, drag, or
ordinary command path. Visible strings use Godot translation lookup; progress
also has an exact text channel, action targets use the design-token minimum,
and reduced-motion mode requires no looping animation.

The base addon has no CommonUI dependency. When
`inventory_common_ui` is enabled, Search, Scan, and discovery Cancel are
registered only while recipient view, focus, screen, and modal state permit.
Discovery Cancel wins over same-screen Back, while a higher modal retains
priority. Closing the screen cancels transient discovery intent state.

## Security and privacy contract

- Session and actor ids are claims supplied by the game. The addon does not
  authenticate a peer; never register values copied directly from untrusted
  client input without transport/game authentication.
- Tokens are authority-generated, recipient-bound, revision-sensitive opaque
  capabilities. Never persist them as canonical ids, share them between
  actors, or decode meaning from their numeric value.
- Recipient projections omit hidden records, references, nested descendants,
  allocator counters, and provider links. Their hash is recomputed after
  redaction.
- Results and rejection diagnostics never return hidden container/item ids.
  Derived count/layout queries return `DISCOVERY_QUERY_REDACTED` until the
  container is indexed.
- Canonical inventory mutations reconcile discovery deterministically. They
  can rotate tokens, cancel a stale task, and advance the discovery revision;
  discovery itself never advances the canonical inventory revision or hash.
- Client wall time, animation completion, and UI state are not authority
  inputs. Only checked trusted elapsed milliseconds can complete work.

## Limits

| Bound | Value |
|---|---:|
| Discovery policies per catalog | 256 |
| Registered recipients | 256 |
| Indexed containers per recipient state | 512 |
| Revealed items per recipient state | 4,096 |
| Opaque token bindings | 8,192 |
| Discovery idempotency records | 1,024 |
| Authored duration | 86,400,000 ms (24 h) |
| One trusted advance | 60,000 ms |
| View/delta byte budget | 1,310,720 bytes |

These values enter `inventory.feature.discovery`'s canonical configuration
only for catalogs that opt in. Changing one changes discovery compatibility
and manifest identity.

## Troubleshooting

| Diagnostic | Meaning / recovery |
|---|---|
| `DISCOVERY_POLICY_INVALID` (156) | Fix an identifier, instant/duration pair, shell label, or bound before sealing. |
| `DISCOVERY_FEATURE_REQUIRED` (157) | Enable discovery on both the staged container and active profile. |
| `DISCOVERY_RECIPIENT_LIMIT` / `UNKNOWN` (158/159) | Teardown unused recipients, or authenticate/register the exact session/actor first. |
| `DISCOVERY_BUSY` (160) | The actor already has an active search/scan; cancel or finish it before beginning another. |
| `DISCOVERY_REVISION_STALE` (161) | Discard local pending state and request a fresh recipient view. |
| `DISCOVERY_NOT_INDEXED` (162) | Search the container before scanning entries or asking disclosed queries. |
| `DISCOVERY_TOKEN_INVALID` (163) | Token is stale, cross-recipient, or fabricated; never retry it against another view. |
| `DISCOVERY_TASK_NOT_FOUND` (164) | Cancel/advance arrived without an active task. Refresh the view. |
| `DISCOVERY_ELAPSED_INVALID` (165) | Trusted advance was zero, negative, or above 60,000 ms. |
| `DISCOVERY_TARGET_STALE` (166) | Canonical mutation/access/relevance removed the target; apply the emitted replacement view. |
| `DISCOVERY_QUERY_REDACTED` (167) | The requested answer would cross the current disclosure boundary. |

For executable coverage, run the native suite,
`tests/inventory_system/discovery/inv_discovery_main.tscn`, and
`tests/inventory_common_ui/inv_cui_main.tscn`. Windowed rendered evidence is
generated by `inv_discovery_visual_qa.tscn`.
