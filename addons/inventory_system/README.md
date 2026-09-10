# Inventory System

`inventory_system` is the canonical reusable inventory addon. Its approved
architecture separates deterministic authority from engine integration and
presentation:

```text
native/core       definitions, feature composition, runtime, transactions
native/protocol   bounded DTOs, codecs, snapshots, deltas, compatibility
native/godot      versioned ClassDB façade
native/resources  editor-visible authoring resources copied into native values
native/tests      engine-free unit, property, golden, and fuzz tests
runtime           snapshot/intent presentation model
controls          replaceable renderers and interaction primitives
editor            validation, previews, and diagnostics
```

The implementation is being delivered in verified slices. The current `0.4.0`
slice contains the engine-independent contract, catalog, feature registry,
manifests, recipient-safe observer protocol, and the server/game-owned
`InventoryNetworkGateway` transport-neutral ingress/egress façade. The gateway
does not create RPCs or own a transport; the game supplies its authenticated
peer/session/epoch context and policy callbacks. Accepted exact replays return
normalized no-event/no-delta receipts, reconnects preserve bounded grants and
rate budgets, and unload/replacement invalidates the affected generation
before its lifecycle notification.

The addon may not depend on CommonUI or Gameplay Abilities. Those integrations
will live in separately enableable one-way adapter addons.

## Start here

Copy this complete directory to `res://addons/inventory_system/`, including
the matching native library under `bin/`, then enable **InventorySystem** in
**Project > Project Settings > Plugins**.

- [How the Inventory System works](docs/how-it-works.md) explains the catalog,
  authority, placement, transaction, snapshot, replication, discovery, and UI
  boundaries as one end-to-end flow, with a minimal offline example.
- [Documentation index](docs/README.md) links the focused authoring,
  integration, API, presentation, networking, troubleshooting, compatibility,
  and verification guides included with the addon.

The full source checkout also carries the engine-independent behavior contracts
and compatibility policy under [`docs/inventory/`](../../docs/inventory/).
