# Task 5.3 authoritative body-hitbox repair evidence

Result: **REPAIR CANDIDATE PASS; independent re-acceptance pending**.

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
- The later metadata repair removes the redundant public `is_bound`, numeric
  binding/generation and scalar snapshot getters. The only binding/snapshot
  metadata readers are now `binding_provenance(capability)` and
  `snapshot_metadata(capability)`, both guarded by exact current bearer identity
  and recursively immutable. A retained world reference therefore cannot read
  replacement-raid metadata or reacquire replacement-binding provenance.

The reviewer defects were first reproduced against `09463f2` as `9/9`
expected security-contract failures; see `review_fail_before.log`. The same
cases are retained as a permanent passing contract.

The metadata-leak rejection of `758eef0` was separately reproduced after adding
the permanent same-world replacement case: the then-public six scalar getters
produced `6` expected failures in a 72-check run. See
`metadata_rebind_fail_before.log`. The repaired contract passes `72/0`.

No task 5.4 shot/consequence adapter, 5.6 damage/injury behavior, 5.11
presentation, UI, weapon-instance creation, or presentation-driven authority
was added. The repair authored no task-ledger or truth-spec change; required
mainline merges carry their independently accepted project documentation.

## Verification

All commands ran from `/Volumes/Data/codes/codex-workspace/zerkov-5-3`.

| Check | Result |
| --- | --- |
| Editor import/parse | exit `0`; no script/parser/runtime error diagnostics |
| Promoted body-hitbox contract | `BODY_HITBOX_RESULT checks=111 failures=0` |
| Adversarial overlap/tie/obstruction/ordering/lifecycle contract | `BODY_HITBOX_ADVERSARIAL_RESULT checks=173 failures=0` |
| Reviewer ABA/auth/immutability/metadata regression | `BODY_HITBOX_REVIEW_REGRESSION_RESULT checks=72 failures=0` |
| Combat content | `COMBAT_CONTENT_RESULT checks=79 failures=0 weapon_count=1` |
| Health/ability content | `HEALTH_ABILITY_CONTENT_RESULT checks=392 failures=0` |
| Authority replay | `AUTHORITY_REPLAY_RESULT checks=81 failures=0` |
| Identity | `IDENTITY_CONTRACT_RESULT checks=18442 failures=0 unique=9216` |
| Session lifecycle (domain only) | `SESSION_LIFECYCLE_RESULT checks=44 failures=0` |
| Units/clock | `UNITS_CLOCK_CONTRACT_RESULT checks=29 failures=0` |
| Strict change validation | `Valid` |
| Cached diff check | exit `0` |

Accepted contract executions total `19423` raw checks with `0` failures.
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

## Mainline task 5.2 integration verification

Recorded: `2026-09-11T03:44:19Z`

Mainline commit `f94222068ec398e4480e049563c496cedb13ff41` was merged by
`adbcfe7b06b342e13334ea7bd0e9fb8cd46ec1d8`. The automatic merge retained
task 5.2's phase-ordered weapon actor context and added only task 5.3's
side-effect-free authorization port relative to mainline `RaidAuthority`.
Relative to the repaired task 5.3 parent, the merge added task 5.2's weapon
context implementation without changing body-hitbox sources or contracts.

Fresh post-merge verification ran the headless editor import first, then only
the three focused task 5.2 domain contracts and three focused task 5.3 domain
contracts. Task 5.2 passed `398/0`; task 5.3 passed `337/0`; strict change
validation returned `Valid`; diagnostic and diff checks were clean. See
`integration_f942220.log` for the exact commands and result lines. No UI,
viewport, visual, composition, inventory UI, or screen-size suite was run.
The `RaidAuthority` source seal was refreshed to bind the accepted merged
5.2/5.3 authority surface.

## Metadata-capability repair and current-main integration

Recorded: `2026-09-11T04:14:21Z`

The metadata repair is commit
`21596eabaa8ec484d9967562424bd52373a17a16`. Current mainline
`c08a39b9026c9f45fd666d61a5c5d96b211e178b` was then merged by
`832877c09203d0598f3ea8db38a8e421c0a06436` without a textual conflict.
Mainline's task 4.11 inventory/UI additions do not alter the hitbox or weapon
context authority seams. Historical 1920x1080 evidence arrived through that
mainline commit; no UI, visual, viewport, runtime-capture or screen-size command
was executed by this repair.

Final verification ran a fresh headless editor import before tests. The focused
task 5.2 contracts passed `398/0`; the focused task 5.3 contracts passed
`356/0`; strict validation returned `Valid`; accepted outputs contained zero
forbidden diagnostics. See `metadata_capability_repair.log` for exact commands
and results. Source and packet hashes below seal the post-merge repair state.

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

## Independent acceptance

Accepted on 2026-09-11 at immutable head
`c0b732693aefa578de2cf2d2359d16fad19c819f` with no P0-P3 findings.
The final independent pass verified that every public metadata read requires
the exact current binding object, stale holders cannot inspect a replacement
raid, and no token-reacquisition getter remains. Task 5.3 passed `356/0` and
the accepted task 5.2 compatibility matrix passed `398/0`, for `754/0`
combined. Import diagnostics, source/packet seals and diff checks were clean.
No UI, viewport, visual, responsive, compact or screen-size suite ran.

## Acceptance reopened

Reopened on 2026-09-11 after a fresh audit against main
`c265d3a4efd9b49f840b87e201ceb8f4b661d26b`. Godot's standard
`Object.get()` and property-list reflection can still recover the live
`_active_binding_capability` from a retained world after a replacement bind.
The reacquired exact object authorized replacement metadata reads, snapshot
publication, a ray query and release. The prior acceptance therefore did not
prove its stated stale-holder isolation claim. Task 5.3 remains open until a
new immutable repair passes focused independent review. The reproducer was a
headless domain probe; no UI, viewport, visual, responsive, compact or
screen-size suite ran.

## Opaque-binding repair candidate

Recorded: `2026-09-11T05:21:08Z`

The current repair is implemented at immutable commit
`c0fbaad2575796c8729ee360a9eca51f62c52bc6`. Exact current main
`d4b407fcba49bb2e97b7db1300b597ecf1c5df75` was merged by
`f942e689ef0ae0e90f8bb296f52eebe160c3b875`; task 5.3 remains open while
the independently accepted 7.9 and 8.3 ledger entries remain checked.

`BodyHitboxWorld2D` no longer retains the exact capability object, a weak
reference, a bound callable, the raw lease, or the capability instance ID.
Each bind generates a fixed 32-byte CSPRNG lease and returns it only inside the
new bearer. The world stores a SHA-256 commitment over that lease, the
candidate object's identity, and exact world/authority/generation/token
context. Guard checks recompute and compare the commitment without publishing
it. Copying the valid lease into a different same-class object therefore does
not authorize it. Release first clears the commitment and erases the returned
object's lease, then clears geometry/replay/lifecycle state.

Binding schema v2 removes `capability_instance_id`. Binding token and other
stable provenance remain available but are not credentials. No bearer, raw
lease, commitment, callable, or capability instance ID appears in binding
provenance, snapshot metadata, ray results, the query replay ledger, or
canonical digests. Task 5.4's active repair was coordinated against the
unchanged method signatures: its adapter receives the bearer only as a
transient bind/phase-operation argument and retains no bearer, secret, or
equivalent callable member.

The new permanent regression was first run against the current-main vulnerable
source and failed `8` of `14` security assertions. Standard property discovery
and `Object.get("_active_binding_capability")` recovered the exact replacement
object, which then read metadata, queried, published, and released. The same
contract now passes `14/0`; it additionally probes recursive properties,
metadata, weak/callable/nested members, copied-secret and commitment forgeries,
post-query replay state, release/rebind, and synchronous lease erasure. See
`capability_encapsulation_fail_before.log` and
`capability_encapsulation_repair.log`.

Final merged verification passed task 5.3 `370/0`, task 5.2 compatibility
`398/0`, and adjacent headless domain contracts for authority, session, units,
combat content, health abilities, identity, combined add-ons and the newly
merged ProfileStore. The Godot domain total is `20521/0`; toolchain `7/0`,
vendor `4/0`, clean editor import, strict spec validation, diagnostics, hashes
and diff checks also pass. A first optional ProfileStore execution collided
with an old shared `user://` test fixture and is explicitly excluded; its clean
nonconcurrent rerun passed `527/0`. No UI, screen, viewport, visual, responsive,
compact, composition, inventory-UI, runtime-capture, or display-size suite ran.

This section records a candidate, not independent acceptance. The 5.3 checkbox
remains open for the primary reviewer.

## Opaque-binding repair independent acceptance

Accepted on 2026-09-11 at immutable candidate
`cd2346b71e52c7e430980003a455708d7769d56f` after a fresh detached-worktree
review found no P0-P2 correctness findings. The reviewer confirmed that the
world retains no live capability object, weak reference, callable, raw lease,
or published capability identifier, and that release/rebind leaves stale,
copied, reflected, serialized, reconstructed, and cross-world values inert.

The independent matrix passed task 5.3 `370/0`, task 5.2 compatibility
`398/0`, and adjacent headless domain contracts `19753/0`, for a Godot-domain
total of `20521/0`. Clean editor import, strict spec validation, source and
packet hashes, toolchain checks, vendor checks, and `git diff --check` also
passed. No UI, screen, viewport, visual, responsive, compact, or alternate-size
test was run. Task 5.3 is accepted and its ledger checkbox is now closed.
