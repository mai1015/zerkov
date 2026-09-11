# Task 5.2 implementation evidence

Status: implementation complete; awaiting the mandated independent acceptance
review and subsequent fresh Astra checkpoint. This packet is implementation
evidence, not self-acceptance and not release evidence.

## Scope implemented

- `WeaponInstanceContextAdapter` creates a real empty AKM `WeaponAuthority`
  instance from the canonical equipped-inventory mapping in raid tick phase 5.
- The stable instance and its mechanical state remain dormant while that exact
  stable inventory item is unequipped or moves through id-preserving inventory
  custody, and are reused with the same reload binding when it returns and
  re-equips.
- Canonical `REMOVED` destroys an item id. Canonical `DROPPED` also retires that
  id because Inventory System exports bounded value data without a stable item
  id; reinsertion is a new identity and does not claim the retired mechanical
  state. Retired records are cleaned before new-instance admission, so 17
  consecutive equip/drop/reinsert cycles do not consume the live-id cap.
- Destruction, explicit teardown and owner-first invalidation settle or
  terminally quarantine reload state, deregister the exact binding, remove the
  native weapon and release the provider handler. Owner-loss quarantine is
  allowed only after the inventory runtime is provably gone, is generation and
  reservation scoped, and never mutates live inventory. Native cleanup failure
  retains the record, native instance, handler and quarantine proof for retry.
- Provider-handler removability is preflighted before any weapon/reload mutation.
  A dependent consumer therefore rejects misordered release with the exact
  native snapshot and reload binding intact; consumer-first retry succeeds.
- `RaidAuthority` phase handlers retain their prior default lexical ordering and
  add a bounded priority/dependency contract. The context provider is explicitly
  ordered before consumers, consumers release first, and stale captured callbacks
  are generation-checked no-ops.
- Binding pins the exact task-5.1 native content fingerprint and continuously
  fails closed if the live `WeaponAuthority` is reconfigured to other valid content.
- `RaidAuthority` admits actor liveness/usability only during preparation or
  phase 7 and admits a converted current-tick firing pose only during movement.
- Fire context is available only in phase 5, fails closed without a current
  pose, obtains equipment directly from the current native inventory snapshot,
  and adds only neutral trusted modifiers.
- The machete is reported as deferred rather than fabricated in Weapon System
  V1, whose installed catalog has no melee mechanism. Melee remains task 5.8.
- `ZWorldUnits` now owns normalization into Weapon System's fixed direction
  scale of 1,000,000.

## Automated evidence

All Godot checks use the repository-pinned executable:

`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`

| Evidence | Result |
| --- | --- |
| `weapon_instance_context_contract.log` | 306 checks, 0 failures |
| `units_clock_contract.log` | 32 checks, 0 failures |
| `authority_replay_contract.log` | 81 checks, 0 failures |
| `equipped_item_reconciliation_contract.log` | 123 checks, 0 failures |
| `inventory_weapon_reload_contract.log` | 159 checks, 0 failures |
| `content_contract.log` | 80 checks, 0 failures |
| `session_lifecycle_contract.log` | 44 checks, 0 failures |
| `inventory_intent_adapter_contract.log` | 162 checks, 0 failures |
| `inventory_ability_reconciliation_contract.log` | 546 checks, 0 failures |
| `identity_contract.log` | 18,442 checks, 0 failures |
| `inventory_authority_contract.log` | 79 checks, 0 failures |
| `inventory_projection_contract.log` | 99 checks, 0 failures |
| `inventory_catalog_contract.log` | 537 checks, 0 failures |
| `inventory_mutation_routing_contract.log` | 146 checks, 0 failures |
| `editor_import.log` | exit 0, empty diagnostic log |
| `spec_strict.log` | `Valid`, exit 0 |
| `diff_check.log` | 0 findings; no vendored add-on changes |

The fourteen executable contracts total **20,836 checks and zero failures**. They
were rerun outside the restricted filesystem sandbox so macOS certificate and
user-log access denials do not contaminate the accepted engine logs.

The promoted task contract covers real add-on state and ordered raid phases:
creation from equipment; mutation-free binding; immutable context/publication;
current-tick pose; normalized aim; a 72-tick inventory-backed reload; one
accepted shot; forged-origin rejection without ammunition loss; canonical
equipment=false, usability=false, and liveness=false native rejections;
dormancy/re-equip; exact loaded-state conservation across stable-id transfer
out, replay, transfer back and re-equip; value-only drop identity retirement
and replay across 17 cycles; the explicit 16-concurrent-live-firearm cap;
permanent destruction versus custody change; exact reload-binding deregistration;
provider/consumer ordering, removal preflight and deterministic tie-breaks;
stale callbacks; content-fingerprint mismatch; active-reload owner-first
teardown; upstream reload-recovery quarantine; retryable native cleanup failure;
explicit teardown; and missing-pose failure closure.

## Diagnostics and limits

Final logs must have successful exit status and no `ERROR`, `SCRIPT ERROR`,
assertion, stack overflow, ObjectDB/RID/resource leak, or parser diagnostic.
Vendored add-on source must remain unchanged and `git diff --check` must pass.
`diagnostics_scan.log` records zero forbidden diagnostics across every frozen
log. `frozen_hashes.sha256` binds the ten production/test source and UID files
to this implementation handoff. The parent checkpoint is
`ab036d2a6c102b6692a9d36e7db6a1b8821f0402`.

This task does not claim input routing (5.7), hit resolution/damage (5.3-5.6),
melee authority (5.8), production UI, multiplayer, human playtest approval,
milestone readiness, or release readiness. It supports at most 16 concurrently
live stable firearm identities for one bound player context; a 17th genuinely
live stable identity is outside this task's admitted boundary and fails closed.
Value-only `DROPPED` custody is not a stable-identity round trip.
