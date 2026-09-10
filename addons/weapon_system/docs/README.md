# Weapon System — Documentation Index

This addon is a required native C++ GDExtension: there is no GDScript
fallback (the same "Required Native C++ Runtime" convention
`inventory_system`/`gameplay_abilities` document at their own
`docs/README.md`). Every signature, enum value, limit, and behavior below is
sourced directly from `native/core/`, `native/godot/`, `native/protocol/`,
and `native/resources/`'s own code — including their `_bind_methods()`/
`ADD_SIGNAL`/`ADD_PROPERTY` calls — not inferred from design prose alone.

Zerkov parity evidence, the Zerkov-adoption proposal boundary, and this
addon's compatibility/versioning policy live one level up, in
[`docs/weapon_system/`](../../../docs/weapon_system/) — see that directory's
own `README.md`.

| Document | Covers |
|---|---|
| [`how-it-works.md`](how-it-works.md) | **Start here.** A first-time adopter's end-to-end mental model and working direct-authority example, followed by catalog/runtime separation, instance state, command receipts, fire/reload/recoil/attachments, hitscan/world ownership, snapshots/deltas/prediction, current bridge hardening limits, presentation helpers, and an adoption checklist. |
| [`authoring.md`](authoring.md) | The five sealed V1 definition kinds (hitscan shot profile, recoil profile, attachment definition, ammunition ballistic profile, weapon definition) plus the attachment-slot Resource, every authored field, the sealed integer milli-MOA → nanoradian formula with a worked example, flat attachment slots, and the canonical parts-per-million modifier algebra. |
| [`integration.md`](integration.md) | Authority/bridge roles, command admission and retries, direct-authority modifiers, native world ports, protocol values, and bridge setup with its current wrapper caveats. |
| [`presentation.md`](presentation.md) | Every authority/bridge signal, all seven optional presenter helpers, the canonical/presentation boundary, and why there is no `shot_resolved` signal today. |
| [`verification.md`](verification.md) | Build/test commands, what each suite proves, and a clearly dated release-gate record. Treat recorded counts as historical and rerun the checks relevant to your revision. |
| [`distribution.md`](distribution.md) | Installing the addon, locating/building its native extension, and reading the pre-1.0 platform support matrix. |
| [`troubleshooting.md`](troubleshooting.md) | Common failure modes tied to exact `StatusCode`/`DiagnosticId`/`Rejection` values, including the world-resolution façade gap and network-bridge admission diagnostics. |

## What this slice implements (and what it does not)

Implemented and covered by the documents above: catalog validation and
sealing across all five definition kinds, the complete mechanical command
surface (fire/begin-reload/cancel-reload/configure-attachments/teardown/
tick-advance) with the shared authoritative command gate, deterministic MOA
dispersion and recoil kick/recovery, the flat attachment loadout, ballistic-
profile-aware reload, canonical snapshots/deltas/codecs, and the experimental
`WeaponNetworkBridge`. Optional `weapon_system_inventory` and
`weapon_system_gameplay_abilities` adapters are distributed separately and are
not part of this standalone package.

**Not yet implemented at this layer** (each cited with its exact evidence in
the documents above — do not assume parity with a spec requirement's prose
without checking the citation):

- **No Godot-bound world coordinator.** `wpn::WorldCoordinator` and its five
  ports (`native/core/wpn_world_coordinator.h`, `wpn_world_ports.h`) are
  fully implemented and tested at the C++ level but have no `ClassDB`
  registration — `register_types.cpp` binds `WeaponDefinitionCatalog`,
  `WeaponSystemVersion`, `WeaponAuthority`, and `WeaponNetworkBridge` only. A
  pure-GDScript game must resolve hitscan/obstruction/damage/noise itself
  after `shot_committed`. See [`integration.md`](integration.md)'s
  "World ports" section and [`troubleshooting.md`](troubleshooting.md)'s
  "World resolution never happens" entry.
- **Resource catalogs do not feed live authority.**
  `WeaponDefinitionCatalog` and `WeaponAuthority` own separate native
  catalogs, and there is no `configure_from_catalog()` or sealed-content
  read-back API. Use Resources for authoring validation/fingerprinting and
  provide Dictionary arrays to `WeaponAuthority.configure()` for live
  GDScript use. A successful reconfigure also replaces the runtime and drops
  existing instances.
- **The Godot network bridge is experimental.** The engine-free protocol
  types/codecs and replica are broader than the current Node wrapper. The
  wrapper does not validate handshake contents, namespace client command IDs,
  protect resync/ack RPCs with the normal ownership gate, acknowledge initial
  snapshots, carry committed shots in active deltas, or fully reset on
  reconnect. Its public confirmed snapshot is a small projection. See
  [`how-it-works.md`](how-it-works.md#current-godot-bridge-boundaries).
- Two adapter-layer contract edges are self-declared/read-only rather than
  fully closed: `weapon_system_inventory`'s ammunition trait-agreement is
  self-declared at mapping-seal time (no live post-seal trait query on
  either catalog façade yet), and `InventoryAuthority` has no public method
  to *author* the physical-identity component a multi-inventory setup needs
  — this adapter can only read one back. See
  the separately distributed `weapon_system_inventory` package's "V1 contract
  edge" sections.
- A GAS-adapter code comment (`weapon_gas_adapter.gd`'s `authority_modifiers()`,
  `weapon_gas_mapping_entry.gd`'s `recoil_control_attribute_identifier` doc
  comment) still asserts the recoil-modifier channel has "no live effect" —
  that claim is stale; the channel is live end-to-end as of this worktree.
  See [`integration.md`](integration.md)'s "Authority modifiers" section and
  the separately distributed `weapon_system_gameplay_abilities` package's
  "Known façade gaps" for the verified current behavior.

These gaps are documented, not silently worked around.
