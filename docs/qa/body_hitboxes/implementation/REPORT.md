# Task 5.3 authoritative body-hitbox evidence

Result: **PASS at the scoped implementation/contract level**.

Recorded: `2026-09-11T02:44:42Z`

Branch: `codex/body-hitboxes-5-3`

Implementation base: `150207bbf60d98358c8b1adc4412511eaedf68b3`

Engine: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer.

## Implemented boundary

- Zerkov owns a sealed humanoid profile with head, thorax and abdomen (torso),
  left/right arms, and left/right legs. Its seven body-zone strings exactly
  match `ZerkovHealthAbilityContent` without calling Gameplay Abilities.
- `BodyHitboxWorld2D` consumes complete fixed-unit pose/obstruction snapshots.
  It never reads a `Node2D`, presentation/animation state, physics enumeration,
  Weapon System state, or Gameplay Abilities component state.
- Ray/AABB entry is compared as exact reduced rational values. Distance wins
  first; obstruction wins an exact body tie; obstruction ties use stable ID;
  body ties use stable entity ID, authored zone priority, then stable hitbox ID.
- Snapshot Array order and dictionary iteration order do not affect selection
  or digest. Equal revision divergence, revision regression, stale
  remove/re-add, malformed records, out-of-range geometry, and capacity excess
  fail before committed geometry changes.
- Query identities are stable `ZRequestId` values. Identical replay returns a
  detached recorded result; reuse with divergent input fails closed. Authority
  generation plus a monotonic binding token prevents stale/ABA rebind access.

No task 5.4 shot/consequence adapter, 5.6 damage/injury behavior, 5.11
presentation, UI, weapon-instance creation, or presentation-driven authority
was added. The approved task ledger and truth specs were not edited.

## Verification

All commands ran from `/Volumes/Data/codes/codex-workspace/zerkov-5-3`.

| Check | Result |
| --- | --- |
| Editor import/parse | exit `0`; no script/parser/runtime error diagnostics |
| Promoted body-hitbox contract | `BODY_HITBOX_RESULT checks=93 failures=0` |
| Adversarial overlap/tie/obstruction/ordering/lifecycle contract | `BODY_HITBOX_ADVERSARIAL_RESULT checks=150 failures=0` |
| Combat content | `COMBAT_CONTENT_RESULT checks=79 failures=0 weapon_count=1` |
| Health/ability content | `HEALTH_ABILITY_CONTENT_RESULT checks=392 failures=0` |
| Authority replay | `AUTHORITY_REPLAY_RESULT checks=81 failures=0` |
| Identity | `IDENTITY_CONTRACT_RESULT checks=18442 failures=0 unique=9216` |
| Session lifecycle | `SESSION_LIFECYCLE_RESULT checks=44 failures=0` |
| Units/clock | `UNITS_CLOCK_CONTRACT_RESULT checks=29 failures=0` |
| Combined add-ons | `ADDON_SMOKE_RESULT checks=155 failures=0` |
| Strict change validation | `Valid` |
| Cached diff check | exit `0` |

Accepted contract executions total `19465` raw checks with `0` failures.
Headless output and the editor-import output were scanned because Godot may
exit successfully after script errors; the accepted outputs contain no
`SCRIPT ERROR`, `Parse Error`, `ERROR:`, invalid-call, or assertion-failure
diagnostic.

Exact commands and result lines are retained in the sibling log files. Source
hashes are in `frozen_sources.sha256`; `packet.sha256` seals this evidence
directory after the report is finalized.

## Deliberate limits / follow-up boundaries

- This is the offline, deterministic spatial fact boundary. Task 5.4 still
  must validate a committed shot, call it once, and emit/deduplicate the stable
  hit or miss consequence. A returned hit does not apply damage.
- The first profile accepts exact quarter-turn facing and uses integer AABBs;
  arbitrary-angle/polygonal body shapes are not claimed.
- Combat geometry is bounded to ±1500 canonical world units, 64 live bodies,
  256 live obstructions, 256/1024 retained body/obstruction identity histories,
  16 exclusions per query, and 4096 recorded query results per binding.
- Obstructions in this task are explicit AABBs. Sawmill collision authoring,
  movement publication, and any richer authored geometry remain their owning
  world tasks.
- There is no multiplayer, rendering, damage, injury, healing, death,
  settlement, or human combat-feel evidence in this packet.
