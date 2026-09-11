# Task 5.3 authoritative body-hitbox repair evidence

Result: **PASS at the scoped implementation/contract level**.

Recorded: `2026-09-11T03:35:12Z`

Branch: `codex/body-hitboxes-5-3`

Implementation base: `150207bbf60d98358c8b1adc4412511eaedf68b3`

Rejected implementation: `09463f291cfe70fddbd59d48e0592655194a272a`

Engine: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer.

## Repaired boundary

- Each successful bind now mints and returns one opaque exact-object
  capability. The world does not expose an active-capability lookup. Every
  snapshot publication/removal, query, replay, metadata read and release checks
  exact bearer identity. Release revokes the bearer before clearing state;
  authority teardown fails before query normalization or replay lookup.
- Binding captures the exact world and `RaidAuthority` instances plus stable
  raid, session, authority epoch/generation/token and owner actor/source
  provenance. Runtime instance IDs are diagnostic only and remain outside
  canonical snapshot/query-result hashes.
- `RaidAuthority.has_authorized_actor_source` is a side-effect-free,
  non-enumerating ownership port. Bind owner, snapshot publisher, every body
  entity/source and every query actor/source must belong to the bound
  authority's private set. Well-formed foreign actors fail closed.
- Queries carry stable raid/session/epoch/owner/query-actor provenance in their
  canonical fingerprint. Numeric generation/token collisions alone grant no
  access.
- Profile declarations/entries, validation findings, generated hitboxes,
  binding provenance, snapshot metadata, accepted hit/miss/obstruction facts,
  replay results and rejections are detached and recursively read-only. The
  mutable replay ledger is never published.
- Exact rational ray/AABB arithmetic and ordering are unchanged: distance;
  obstruction before body at an exact tie; obstruction ID; or entity ID, zone
  priority and hitbox ID. Capacity, revision and obstruction behavior remain
  bounded and fail closed.

The reviewer defects were first reproduced against `09463f2` as `9/9`
expected security-contract failures; see `review_fail_before.log`. The same
cases are retained as a permanent passing contract.

No task 5.4 shot/consequence adapter, 5.6 damage/injury behavior, 5.11
presentation, UI, weapon-instance creation, or presentation-driven authority
was added. The approved task ledger and truth specs were not edited.

## Verification

All commands ran from `/Volumes/Data/codes/codex-workspace/zerkov-5-3`.

| Check | Result |
| --- | --- |
| Editor import/parse | exit `0`; no script/parser/runtime error diagnostics |
| Promoted body-hitbox contract | `BODY_HITBOX_RESULT checks=111 failures=0` |
| Adversarial overlap/tie/obstruction/ordering/lifecycle contract | `BODY_HITBOX_ADVERSARIAL_RESULT checks=173 failures=0` |
| Reviewer ABA/auth/immutability regression | `BODY_HITBOX_REVIEW_REGRESSION_RESULT checks=53 failures=0` |
| Combat content | `COMBAT_CONTENT_RESULT checks=79 failures=0 weapon_count=1` |
| Health/ability content | `HEALTH_ABILITY_CONTENT_RESULT checks=392 failures=0` |
| Authority replay | `AUTHORITY_REPLAY_RESULT checks=81 failures=0` |
| Identity | `IDENTITY_CONTRACT_RESULT checks=18442 failures=0 unique=9216` |
| Session lifecycle (domain only) | `SESSION_LIFECYCLE_RESULT checks=44 failures=0` |
| Units/clock | `UNITS_CLOCK_CONTRACT_RESULT checks=29 failures=0` |
| Strict change validation | `Valid` |
| Cached diff check | exit `0` |

Accepted contract executions total `19404` raw checks with `0` failures.
Headless output and editor-import output were scanned because Godot may exit
successfully after script errors; accepted outputs contain no `SCRIPT ERROR`,
`Parse Error`, `ERROR:`, invalid-call or assertion-failure diagnostic. The
intentional fail-before reproduction is explicitly excluded from that scan.

No UI, inventory, composition, combined-add-on, viewport or screen-size suite
was invoked for this repair. All executed contracts are headless domain tests;
therefore no output below the product's exact 1920x1080 support boundary was
created or claimed.

Exact commands and result lines are retained in sibling log files. Source
hashes are in `frozen_sources.sha256`; `packet.sha256` seals this evidence
directory after the report is finalized.

## Deliberate limits / follow-up boundaries

- This remains the offline deterministic spatial-fact boundary. Task 5.4 must
  validate a committed shot, call it once and emit/deduplicate its consequence.
  A returned hit does not apply damage.
- Runtime object identity authenticates an in-process bind and is intentionally
  not serialized into canonical replay bytes. Durable/network capability
  transport is not claimed by the offline first playable.
- The first profile accepts exact quarter turns and integer AABBs; arbitrary
  angles and polygons are not claimed.
- Geometry stays bounded to +/-1500 canonical world units, 64 live bodies, 256
  live obstructions, 256/1024 retained body/obstruction histories, 16 query
  exclusions and 4096 replay-ledger results per binding.
- Obstructions are explicit AABBs. Sawmill collision authoring and movement
  publication remain with their owning world tasks.
- There is no rendering, damage, injury, healing, death, settlement, UI or
  human combat-feel evidence in this packet.
