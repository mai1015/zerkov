# Task 8.4 implementation evidence

Status: **FROZEN FOR INDEPENDENT REVIEW**

This packet covers only Ledger 8.4: the typed/read-only `RaidView`,
`InventoryView`, `HealthView`, `TaskView`, `MapView`, `BunkerView` and
`SummaryView` contracts.

## Implemented boundary

- Seven global typed GDScript contracts live in `game/presentation/views/`.
- All contracts inherit common generation, revision, authoritative tick,
  synchronization-state and diagnostic metadata from `ZReadOnlyView`.
- Ready projections validate required stable IDs, content IDs, typed enum
  values and domain-specific numeric bounds before construction.
- Unavailable projections make loading, resynchronizing, stale and disconnected
  states explicit without fabricating canonical values.
- Stable identity and nested-record accessors return detached values.
- Ready factories populate validated payloads before sealing; direct base
  initialization cannot produce an incomplete ready subtype. Provenance,
  retained nested records, and returned snapshot records ignore later external
  member writes, while array and dictionary accessors are structurally read-only.
- Stale, resynchronizing, and disconnected views require and retain the subject
  identity appropriate to the contract; loading/unbound views may lack one.
- Inventory containers retain the exact revision of their native inventory and
  reject conflicting revisions for containers belonging to the same inventory.
- Health views reject contradictory healthy/injured/destroyed and alive/dead
  combinations.
- `SummaryView` requires raid and settlement identities plus a SHA-256 audit
  digest and exposes outcome, kills, damage, injuries, loot value, task results,
  rewards, losses and exceptional corrections.
- `BunkerView` represents unimplemented meta stations with a typed
  `FEATURE_GATED` state and mandatory non-color-only reason.

No screen binding, layout, navigation, authoritative mutation, persistence,
add-on source, multiplayer behavior or public-release claim is included.

## Automated results

The accepted pinned executable was:

```text
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
```

| Check | Result |
| --- | ---: |
| View contracts | 75 checks, 0 failures |
| Inventory immutable projection | 99 checks, 0 failures |
| Raid authority replay | 81 checks, 0 failures |
| Combined add-on load | 155 checks, 0 failures |
| Whole-project route smoke | 28 screens, 0 missing/capture errors |
| Editor import/parse | exit 0, no diagnostic |
| Strict change validation | `Valid` |
| `git diff --check` | pass |

The focused suite constructs every ready contract, constructs explicit
unavailable states, checks typed identities/enums/accessors, verifies collection
read-only flags, attempts writes through detached and retained nested records and
through sealed provenance, rejects incomplete direct ready initialization,
checks per-inventory revisions and stale subject identity, and rejects invalid
IDs, bounds, health combinations, feature gates and digests.

Exact command output is in [automated_checks.log](automated_checks.log), import
output is in [editor_import.log](editor_import.log), and the diagnostic policy
and result are in [diagnostics_review.md](diagnostics_review.md).

## Freeze

[frozen_sources.sha256](frozen_sources.sha256) seals 19 implementation and test
files. Independent review must reject the packet if any listed hash changes.
The task checkbox remains open until independent acceptance and a fresh final
validation both pass. Human playtest approval remains false.
