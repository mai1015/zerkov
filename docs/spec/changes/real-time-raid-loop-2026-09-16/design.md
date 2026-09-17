# Design and bottleneck review

Status: proposed, not implemented. Source reviewed: PR #22 at `52121cbbf369ad198daff808e05cbd0c3f4485e8`; separate teardown fix `5bc2f1fb1296c923e786d83d3c665af8c1d4f623`.

## 1. What the evidence actually says

The retained original profiler packet `zerkov-raid-profile-a6f6a1f.zip` identifies baseline `a6f6a1fd5af2e1eb8114ac71db2fee491223c731`. Its instrumented idle stage reports 126.830 ms mean root tick, 83.604 ms summed callback scans and 35.011 ms summed handler bodies. Health contributes 22.500 ms of those bodies. Movement/combat show the same pattern. These historical instrumented attribution numbers are NOT current-commit speedups, windowed FPS or target-hardware measurements. Roughly two thirds of the baseline tick is scanning; removing that cost alone would still leave more than a 60 FPS frame budget in handler bodies on that CI host.

The current source paths responsible are:

- `game/raid/raid_authority.gd`: `PhaseHandlerRelay.configure`, `phase_handler_callback_is_safe`, `_variant_graph_contains_hitbox_bearer`.
- `game/raid/raid_callback_capture_scanner.gd`: a fresh recursive graph walk for every callback; native schemas are cached but current graphs are not.
- `game/combat/content/zerkov_health_ability_content.gd`: `preflight_component`, `_validate_catalog_subset`, `_find_definition`.
- `game/combat/health_consequence_adapter.gd`: `_audit_actor_state`, `_health_state_digest`, `_actor_snapshot_from_record`.

For the profiled 18-handler, 3-actor scene at 60 simulation ticks per second, the normal path implies about 1,080 callback scans and at least 540 catalog-validator invocations per simulated second (three validators per health preflight). Extra gameplay preflights can add more. This is a workload calculation, not a newly measured throughput result.

## 2. Separate three boundaries

### Construction and activation

Resolve and validate content, identities, ownership, handler ordering and component compatibility before ACTIVE. Compile a closed handler roster. Resolve stable identifiers once. Retain an immutable active representation rather than a mutable authoring graph. Unknown/dynamic callbacks must not silently receive the optimized production registration path.

### Authoritative mutation

Every mutation still checks live raid/session generation, actor ownership, component liveness, permitted phase, current executor registration and command identity. Duplicate commands remain idempotent; conflicting retries fail. Revocation, teardown and ownership replacement take effect synchronously. These checks are bounded and remain enabled in release builds.

### Diagnostics and authoring

Deep schema/provenance audits remain required at admission and content changes, and in exhaustive regression tests. Optional diagnostic sweeps are additional checks, never the only protection against mutable active state. Same-process callback graph inspection is an internal leakage guard, not a substitute for validating untrusted network intent. Its existing contract cannot be silently removed under a performance flag.

## 3. Closed production dispatch: proposed replacement

The production roster contains data-only handler IDs, phase/order, executor identity, actor identity and generation. A game-owned dispatcher maps these to reviewed executor methods. Registration is frozen for the active generation. A record does not retain an arbitrary user Callable or a capability-bearing argument graph.

The replacement is acceptable only after proving that writable hitbox capabilities are never published to callback owners, queries or presentation; mutation entry points enforce the current invocation context; reflected roster edits cannot install a different executor; and teardown/owner-loss behavior remains exact. Generic callbacks retain the old scanner in an explicitly separate supported diagnostic path, or are rejected for production activation. There is no automatic 'trusted' exemption based only on a script filename.

This requires reviewing affected hitbox/phase-handler contracts. It is not equivalent to caching a successful graph scan by callback identity, and an epoch field without complete mutation control is not sufficient.

## 4. Health/catalog work

A safe first increment does not change live validation semantics: build expected immutable identifiers/fingerprint metadata once; replace repeated array getter calls and quadratic searches with one fresh duplicate-aware index per definition category; retain full validation of the current actual catalog. Do not retain a mutable expected Resource catalog in a public cache.

The structural increment validates and compiles at activation, then uses sealed active content plus a content generation. It must copy or otherwise isolate all nested active definitions from mutable authoring Resources. If existing native components retain aliases, do not claim immutability or remove per-tick validation. Evaluate the installed API first; a required native change is a separate addon decision and promotion. Changes while ACTIVE are rejected or require an explicit stop/rebuild/revalidation transition. Mutating nested arrays, metadata, identifiers or modifiers after a previous successful check must never silently alter active semantics.

Runtime health checks continue to validate current component liveness, bounds, grant ownership, death state, scheduled bleed state and admitted gameplay mutations. Bleeding, stamina, hydration, recovery and due work retain their current 60 Hz timing semantics; expensive catalog construction is not what makes those time-dependent effects correct.

## 5. Projections and history

Produce a canonical immutable actor snapshot after relevant state changes and publish it once to readers. Specify every dependency before using a revision key: health, stamina, hydration, tags, equipment, transform, lifecycle and generation as applicable. Separate the frame/tick envelope from reusable actor data. Two equal revisions are not a valid cache key if a visible field can change without advancing them.

Do not rebuild the same actor snapshot for every consumer in the same authoritative state. Keep digest/replay semantics exact. Profile long raids as well as short samples: ledgers and histories must not cause validation work to grow with raid age.

## 6. Budget and measurement protocol

60 FPS gives 16.667 ms per displayed frame; 120 FPS gives 8.333 ms. Preserve the existing 60 Hz authoritative clock; render rate is a separate concern. Proposed initial CPU budget: authoritative tick p95 <= 4 ms and p99 <= 6 ms on a recorded reference machine. These are acceptance targets, not achieved measurements, and the frame can still fail due to rendering or presentation.

Record exact commit, engine identity, native artifact hashes, OS/CPU/GPU, renderer, resolution, build configuration, VSync and scene population. Measure uninstrumented before/after pairs for idle, movement, reload/fire, AI combat, loot/UI, extraction and death. Report p50/p95/p99, maximum, allocation/retention signals and tick debt. Keep instrumentation out of the production checkout. Compare equivalent authoritative traces and terminal save fingerprints.

Then perform at least a five-minute windowed run, with warm-up excluded, at the requested 1920x1080 validation size. Report displayed frame p95/p99 and count frames exceeding 16.667/8.333 ms; report pause/resume and long-raid behavior separately. Shared macOS CI establishes functional evidence and relative profiling, not operator-hardware FPS acceptance. Do not make an absolute shared-runner performance threshold a flaky merge gate before calibrating hardware and noise.

## 7. Migration/rollback

Each production optimization is a separate reversible commit with its own same-workload comparison. Keep the old scanner/reference and current mutation adversaries until replacement contracts are approved and proven. Do not merge a 'fast mode' that disables safety or changes simulation rate. Stop migration on any trace mismatch, runtime diagnostic, lost revocation or undefined content invalidation. Partial improvements are labeled partial, never 60/120 FPS acceptance.
