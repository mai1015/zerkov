# Task 5.2 implementation evidence

Status: implementation complete; awaiting the mandated independent acceptance
review and subsequent fresh Astra checkpoint. This packet is implementation
evidence, not self-acceptance and not release evidence.

## Scope implemented

- `WeaponInstanceContextAdapter` creates a real empty AKM `WeaponAuthority`
  instance from the canonical equipped-inventory mapping in raid tick phase 5.
- The stable instance and its mechanical state remain dormant while that exact
  inventory item is owned but unequipped, and are reused on re-equip.
- Destroyed/transferred-out items interrupt reload coordination before native
  instance removal; explicit release and owner-first invalidation are covered.
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
| `weapon_instance_context_contract.log` | 157 checks, 0 failures |
| `units_clock_contract.log` | 32 checks, 0 failures |
| `authority_replay_contract.log` | 81 checks, 0 failures |
| `equipped_item_reconciliation_contract.log` | 123 checks, 0 failures |
| `inventory_weapon_reload_contract.log` | 159 checks, 0 failures |
| `content_contract.log` | 79 checks, 0 failures |
| `session_lifecycle_contract.log` | 44 checks, 0 failures |
| `editor_import.log` | exit 0, empty diagnostic log |
| `spec_strict.log` | `Valid`, exit 0 |
| `diff_check.log` | 0 findings; no vendored add-on changes |

The seven executable contracts total **675 checks and zero failures**. They
were rerun outside the restricted filesystem sandbox so macOS certificate and
user-log access denials do not contaminate the accepted engine logs.

The promoted task contract covers real add-on state and ordered raid phases:
creation from equipment; mutation-free binding; immutable context/publication;
current-tick pose; normalized aim; a 72-tick inventory-backed reload; one
accepted shot; forged-origin rejection without ammunition loss; canonical
equipment=false, usability=false, and liveness=false native rejections;
dormancy/re-equip; destruction; explicit teardown; owner-first teardown; and
missing-pose failure closure.

## Diagnostics and limits

Final logs must have successful exit status and no `ERROR`, `SCRIPT ERROR`,
assertion, stack overflow, ObjectDB/RID/resource leak, or parser diagnostic.
Vendored add-on source must remain unchanged and `git diff --check` must pass.
`diagnostics_scan.log` records zero forbidden diagnostics across every frozen
log. `frozen_hashes.sha256` binds the eight production/test source and UID files
to this implementation handoff. The parent checkpoint is
`ab036d2a6c102b6692a9d36e7db6a1b8821f0402`.

This task does not claim input routing (5.7), hit resolution/damage (5.3-5.6),
melee authority (5.8), production UI, multiplayer, human playtest approval,
milestone readiness, or release readiness.
