# Inventory System — Documentation Index

This addon is a required native C++ GDExtension: there is no script fallback
(the same "Required Native C++ Runtime" convention `gameplay_abilities`
documents at its own `docs/README.md`). The documents below cover the Godot
façade slice (design task 7.x) as it exists today — every signature, enum
value, and behavior is sourced directly from `native/godot/*.h/.cpp` and
`native/resources/*.h`'s own `_bind_methods()`/`ADD_SIGNAL`/`ADD_PROPERTY`
calls, not inferred from the delta specs.

The engine-independent core, protocol, and compatibility contracts live one
level up, in [`docs/inventory/`](../../../docs/inventory/) (`contracts.md`,
`compatibility.md`, `traceability.md`, `DESIGN.md`) — those documents are the
source of truth for numeric limits, wire rules, and the pre-1.0 compatibility
policy; the documents here are the source of truth for the *Godot-facing
surface* built on top of that contract.

| Document | Covers |
|---|---|
| [`how-it-works.md`](how-it-works.md) | Start here: a first-time adopter's end-to-end mental model of definitions and sealing, runtime ownership, layouts/stacks/nesting, the atomic command pipeline and prepared-quantity participant, receipts/snapshots/deltas, owner and observer replication, discovery, presentation, lifecycle, limits, and a minimal offline example. |
| [`api.md`](api.md) | The primary public façade reference for `InventoryCatalog`, `InventoryAuthority`, `InventoryNetworkGateway`, `InventoryReplicaNode`, `InventoryObserverReplicaNode`, `InventorySnapshotResource`, and the 9 non-discovery authoring `Resource` classes, including the authenticated gateway, recipient-safe observer protocol, and `InventoryContainerConstraints.ACCESS_*` flags. Discovery-specific value types and methods are covered in [`discovery.md`](discovery.md); [`generated/`](generated/) is the structural inventory of every bound class and method. |
| [`authoring.md`](authoring.md) | How to author trait schemas, items, containers (spatial grid / named slots / ordered list), constraints, profiles, and limits as `.tres` resources; how they are validated and registered; the editor "Validate Inventory Catalog" tool; and a worked quickstart from catalog resource to a sealed `InventoryCatalog`. |
| [`integration.md`](integration.md) | Ownership and lifetime rules (who owns what, and for how long), the single-threaded/main-thread contract, the authority boundary, authenticated `InventoryNetworkGateway` ingress/egress, persistence usage, and a full network-integration walkthrough (authority bytes → transport → replica, and the resync loop) with runnable-shape GDScript examples. |
| [`compatibility.md`](compatibility.md) | The façade's view of the six independent version axes, the version-query methods, `session_hello_bytes()`, and a pointer to the canonical compatibility policy and golden-fixture rules in `docs/inventory/compatibility.md`. |
| [`verification.md`](verification.md) | How to build the extension and run every test suite that verifies this addon (native suite, boundary/fixture checks, extension-load smoke, the integration probe, the GDScript contract suite, the presentation/interaction/harness/vertical/dedicated-server suites, and both optional adapters' suites), what each one proves, current check counts, and this addon's sanitizer policy. |
| [`presentation.md`](presentation.md) | The GDScript presentation layer built on the façade: `InventoryPresentationModel`, the renderer registry and container controls, `InventoryInteractionController`, the shared primitives, the full 24-state catalog, and how the optional CommonUI and Gameplay Abilities adapters plug in. |
| [`discovery.md`](discovery.md) | Opt-in staged container discovery: authoring, authority lifecycle, API/protocol and replica flow, recipient-safe projection, presentation/CommonUI behavior, compatibility, limits, security, and troubleshooting. |
| [`distribution.md`](distribution.md) | Installing the addon and its two optional adapters, the dependency direction, building artifacts, platform support state, the checksum/export-smoke tooling, the CI jobs, and a pointer to the pre-1.0 compatibility policy. |
| [`troubleshooting.md`](troubleshooting.md) | Common failure modes (missing GDExtension, catalog seal-order mistakes, command rejection status/diagnostic codes, replica resync, persistence load failures, snapshot visibility surprises) tied to the exact `StatusCode`/`DiagnosticId` values that cause them. |
| [`generated/`](generated/) | Godot `--doctool`-generated XML references for all 22 native Godot-facing classes: 15 base façade/authoring types plus 7 discovery policy/value types. The output is primarily structural, with selected gateway/observer/lifecycle safety descriptions; see that directory's own README for details. |

## What this slice implements (and what it does not)

Implemented and covered by the documents above: catalog validation and
sealing, the complete typed command surface, snapshot/delta/session-hello/
persistence encoding, derived queries, the offline-authority / remote-replica
role split, local value projection, the server/game-owned authenticated
`InventoryNetworkGateway`, and the recipient-safe observer transport
(`inventory-observer-v1` / version 1) with immutable exact-stream binding,
full replacement views, redacted aggregate shells, opaque recipient-local
handles, and resync semantics. Canonical `snapshot_envelope_bytes()` is
owner-only; untrusted peers use `InventoryObserverReplicaNode`.

**Not yet implemented at this layer** (see `integration.md`'s "Authority
boundary" section and `api.md`'s per-class caveats for the exact citation):

- **Direct `InventoryAuthority` calls remain local/trusted.** The gateway is
  the authenticated remote ingress façade, but `InventoryAuthority` still
  hard-codes an always-allow `inv::AllowAllPermissionProvider`; the C++-only
  `inv::PermissionProvider` seam has no Godot binding. The gateway's mandatory
  game-owned world-policy callback supplies that missing policy boundary for
  remote command bytes.
- The gateway requires `ROLE_SERVER_AUTHORITY`, exact hello/epoch admission,
  default-deny class and inventory grants, replay protection, and grant-scoped
  direct egress. It still does not create a transport or RPC endpoint: the
  game owns the connection and obtains the trusted peer from its transport
  (`get_remote_sender_id()` in a Godot RPC handler).

These gaps are documented, not silently worked around, in both the contract
test suite (`tests/inventory_system/contract/inv_contract_main.gd`) and here.
