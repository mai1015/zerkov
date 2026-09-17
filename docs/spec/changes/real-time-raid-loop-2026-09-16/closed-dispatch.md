# R3/R4 implementation: fixed production dispatch, not a cached safety verdict

Status: user-approved staged implementation, candidate awaiting real-native regression and performance evidence. This record refines the approved direction; it does not complete R5/R6/R7 or mark the game as 60/120 FPS-ready.

## Contract change

The production application is trusted executable code, not a sandbox for arbitrary in-process scripts. UI and remote data remain untrusted intents. Previously every callback invocation recursively inspected everything retained by its owner. That made dispatch scale with passive catalogs, snapshots, inventory and accumulated history, even when no gameplay work was due.

The local raid composition now explicitly seals its complete installed named-method roster before ACTIVE, after combat has installed named world grants and revoked the raw hitbox bearer. Each entry captures the exact owner weak reference, Script identity, method, bounded scalar bound arguments, registration identity, phase and raid generation. The roster and ordering commitment are retained behind a write-once lexical policy. No callback-safety boolean or mutable object graph is cached.

Every dispatch still checks the live invocation: ACTIVE/EXTRACTING lifecycle, current authority tick, handler and registration identity, phase, generation, owner liveness and queued-deletion state, exact Script/method/arguments and unchanged roster commitment. Existing roster coherence, Vision-owner provenance, domain mutation authorization, idempotency and teardown checks remain. The authority retains its exact script identity; it is not subclassed.

Generic and diagnostic authorities do not opt in and keep full per-invocation scanning. Explicit calls to `phase_handler_callback_is_safe` continue to inspect the current graph. The production distinction is intentional: retaining unrelated data or even a REVOKED bearer type is not itself a new grant of authority. Actual world APIs must still reject that revoked bearer and enforce their named phase grants.

This is not protection against arbitrary memory editing, an attacker executing trusted scripts, in-place script hot reload, or a compromised engine. A filename alone does not grant production eligibility. Registration is validated before sealing; immutable recorded executable identities and live domain checks enforce the invocation. Changing ownership or the executable roster requires a new composition/generation, not editing an active roster.

## Implementation

- `RaidAuthority.seal_production_dispatch` validates and freezes the complete installed named roster; arbitrary collection/object bound arguments and late registration are rejected.
- `PhaseHandlerRelay` asks the authority to authorize the invocation. Unsealed authorities continue through the original graph scanner.
- `LocalRaidSession.start` opts into the sealed roster only after all existing game-owned/native participants are composed. No clock, gameplay, save or addon-binary changes are made.
- `dispatch_work_counts` exposes a read-only count of actual graph scans so tests distinguish removal of repeated work from merely making it faster.

## Verification

The new closed-dispatch contract exercises unrelated retained-state growth with zero additional graph scans, wrong generation, resealing, late registration, changed roster order, queued owner deletion, Script replacement on the same object, bound-argument substitution, out-of-phase/terminal invocation, raw-bearer revocation and synchronous authority lifetime release. It runs from the existing native local-flow capture contract without replacing its scanner differential tests.

Local isolated Godot 4.7.2 runs: 89 assertions pass twice with clean runtime diagnostics. Those runs use the real GDScript authority and body-hitbox implementation, but a non-instantiated Vision type placeholder and health zone constants to avoid unavailable Linux native addons. They are NOT real-native or full-game acceptance.

The paired real-application profiler compares against `23f727c9af122df20a70db17a16924d75faafc93` and restores all four listed baseline production paths, including authority and local raid composition. Candidate/control/instrumented stage digests must match. The relay column is now named `dispatch_validation`, not `scan`, because the candidate performs bounded identity checks. Work counters show whether any graph scans occur after startup. All native tests, complete extraction/death/save-retry/relaunch and measured before/after results remain pending at this implementation commit.

## Still wrong in the current work model

Health still audits every actor and rebuilds digests each tick; equipment context still reconciles each weapon phase; body/world revisions are still derived from tick; journal consumers still copy historical records; the root still rebuilds all five UI views with a new shared revision. These are separate R5/R6 follow-ups, not fixed by dispatch.

The target is mutation-driven health/equipment/task projections, due-time scheduling for bleeds/reload/effect expiry, change-driven geometry with a separate tick-freshness envelope, incremental journal consumption, and coalesced visible UI publication. Dirty checks must happen before expensive reconstruction. Tick passage alone must not mean every domain changed. Physics and time-dependent movement remain fixed-step; render interpolation is separate. No claimed 60/120 FPS result precedes windowed measurement.
