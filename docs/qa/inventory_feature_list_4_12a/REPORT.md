# Inventory `FEATURE_LIST` normalization evidence

Task 4.12a implementation evidence, generated 2026-09-11T00:19:37Z with the
pinned Godot 4.7.2 Compatibility executable. Independent review is still
required; this packet does not claim human approval.

## Outcome

The stash, world-crate, and corpse profiles now advertise
`inventory.feature.ordered_list` because each nesting-enabled grid can carry an
AKM magazine whose item-provided child is an ordered list. The player profile
uses the same shared feature closure and no longer needs a one-off duplicate
declaration.

The focused native contract creates one 30-round AKM magazine and moves its
complete canonical subtree through:

```text
player backpack -> stash -> world crate -> corpse
```

At every destination it proves:

- the exact known capability-query matrix, plus fail-closed unknown queries;
- unchanged profile item, container, reference, nesting, and component limits;
- stable magazine, provided-container, ammunition, root-container, inventory,
  profile, and manifest identities;
- one canonical parent placement and one ordinal-zero ammunition child;
- exact recursive/root/child mass and count-capacity query results;
- byte-identical repeated persistence encoding and fresh-authority restore;
- byte-identical snapshot encoding and hash after restore;
- two-inventory fail-atomic rejection for a wrong destination layout;
- idempotent accepted-command replay with no repeated events;
- fail-closed conflicting command reuse and atomic restored-capacity rejection.

No UI, presentation adapter, raid owner, vendored add-on, `project.godot`,
truth spec, Forge artifact, or task ledger was changed.

## Final validation

Every listed process exited zero. The Godot outputs were scanned for `ERROR:`,
`SCRIPT ERROR`, warnings, assertions, stack overflow, ObjectDB/RID/resource/font
leaks, and timeout markers; the final diagnostic count is zero.

| Validation | Result |
| --- | ---: |
| Editor import / script registration | exit 0, diagnostics 0 |
| Strict `add-zerkov-playable-raid-2026-09-09` validation | `Valid` |
| Six locked destination add-ons | 6 passed, 0 failed |
| Combined add-on load smoke | 155 / 0 |
| Inventory catalog contract | 543 / 0 |
| Nested-magazine transfer/persistence/query contract | 258 / 0 |
| Inventory authority contract | 79 / 0 |
| Inventory intent-adapter contract | 162 / 0 |
| Inventory mutation-routing contract | 146 / 0 |
| Inventory projection contract | 99 / 0 |
| Inventory weapon-reload contract | 159 / 0 |
| Inventory ability-reconciliation contract | 546 / 0 |
| `git diff --check` | exit 0 |
| **Assertion executions** | **2,147 / 0** |

## Reproduction

From the repository root:

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --editor --import --audio-driver Dummy --quit
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_catalog_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_nested_magazine_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_authority_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_intent_adapter_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_mutation_routing_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_projection_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_weapon_reload_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_ability_reconciliation_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/addons/combined_addons_smoke.gd
python3 tools/vendor_addons.py check --scope destination
python3 /Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py \
  validate add-zerkov-playable-raid-2026-09-09 --type change --strict
git diff --check
```

## Boundaries

- This task makes canonical nested contents safe to expose later; it does not
  expose them or change the existing designed inventory UI. Tasks 4.11 and 8.6
  remain responsible for later presentation work.
- The catalog manifest necessarily changes when capability metadata changes.
  This task proves records created and restored under the normalized sealed
  catalog; it does not add migration for records bearing the earlier manifest.
- Task 4.12 still owns live game-composition replacement and stale
  UI/adapter invalidation. Physical detachable-magazine swapping also remains
  outside this task.

## Sealed implementation inputs

| File | SHA-256 |
| --- | --- |
| `game/content/zerkov_inventory_catalog.gd` | `666ddf8a0d428a632de91bb9bbc7c5bf401b9d8c311d57d533c5581e372921b7` |
| `tests/raid/inventory_catalog_contract.gd` | `5ac24b774e6baa5c80c1b8b2725ff9dfb3f0fdaa380c01030e250e0bf6dc501b` |
| `tests/raid/inventory_nested_magazine_contract.gd` | `468eccce942f257d1127070a14fa1a881c6c3dc17d848479dacefa05dff609ca` |
| `tests/raid/inventory_nested_magazine_contract.gd.uid` | `3f131733ab3fd0ce0b191a9ae25e91dc81636ed78eae3c5fc237dbb012939ffe` |
