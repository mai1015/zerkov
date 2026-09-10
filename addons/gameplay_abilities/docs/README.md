# Gameplay Abilities — Documentation Index

This addon is a required native C++ GDExtension: there is no script
fallback (see `docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/specs/gameplay-ability-platform-support/spec.md`,
"Required Native C++ Runtime"). The documents below cover what is
implemented and verifiable today; each says plainly where it stops.

| Document | Covers |
|---|---|
| [`how-it-works.md`](how-it-works.md) | **Start here.** A first-adopter mental model, definition-to-runtime lifecycle, activation/commit order, tags/attributes/effects, ticks, hooks/tasks/reactions/targeting, authority and prediction flow, failure semantics, budgets, and a minimal runnable example using the shipped sample resources. |
| [`integration.md`](integration.md) | How a game wires ordinary input, CommonUI, AI, and replay/test drivers to activation, Ability Task input, and typed targeting without the addon owning physical input. |
| [`hooks.md`](hooks.md) | The typed authority-only vs. prediction-safe hook contract for both ability execution and effect calculation, why the two variants share no common base, accepted/rejected examples with exact diagnostics and citing test names, the v1 prediction-safe operation set verbatim, `validate_prediction_eligibility`, and the stackable-effect overflow-chain subtlety a naive check misses. |
| [`tasks.md`](tasks.md) | Deterministic execution-owned waits, built-in task kinds, safe hook continuation, logical input, snapshots/restoration, prediction, budgets, and migration from scene-owned waits. |
| [`targeting.md`](targeting.md) | Typed target values and schemas, provider authoring, the per-world coordinator, sessions and `WAIT_TARGET_DATA`, atomic effect batches, networking/security, CommonUI integration, and legacy migration. |
| [`api.md`](api.md) | Public Godot API for the component (18 signals), network bridge (11 signals), world coordinator, typed target wrappers, Ability Task requests, version facade, and authoring resources. |
| [`authoring.md`](authoring.md) | How to author tags, attributes, effects, abilities, cues, target schemas, tag reactions, and network policy resources; the ≥2-dotted-segment identifier rule; the project-wide `GameplayDefinitionCatalog` — identity vs. component-local runtime state, the `gameplay_abilities/default_definition_catalog` project setting, the `GameplayAbilityComponent.definition_catalog` override, legacy migration, mixed catalog/legacy rejection, and the full validation-finding code catalog; quantization of authored decimals; how definitions feed the content manifest and multiplayer compatibility; and running the editor validator (`GameplayDefinitionValidation`/`GameplayDefinitionValidator`). |
| [`reactions.md`](reactions.md) | Every tag-reaction semantic: predicate-edge rules (first/last source, parent-aware descendants) for `ON_ADDED`/`ON_REMOVED`/`WHILE_PRESENT`, canonical dispatch ordering (incl. cancellation-before-reactions), authority-only/no-client-prediction execution, the `WHILE_PRESENT` handle binding lifecycle (failed-application no-retry, externally-removed-handle diagnostics), static cycle rejection (incl. self-loops) and the dynamic chain bound, teardown discard, snapshot/restore without replay, manifest fingerprinting, and the currently-open gap in GDScript-side reaction diagnostics. |
| [`editor_workflows.md`](editor_workflows.md) | Exact, label-precise walkthroughs: picking a tag/attribute in the Inspector, spotting and repairing an orphaned reference, safe catalog rename/delete via the dashboard's usage report, and running the legacy-to-catalog migration flow. |
| [`protocol.md`](protocol.md) | Protocol version and pre-1.0 policy, API version, the manifest algorithm (FNV-1a64 canonical), the canonical byte codec, exact message-envelope and handshake byte layouts, the per-`MessageType` byte-limit table, the complete `ga_limits.h` constants table, the supported tick-rate range, the fixed-point representation, the identifier grammar (including the "identifiers need ≥ 2 segments" pitfall), the handshake compatibility matrix, and security/v1-exclusion rules. |
| [`determinism.md`](determinism.md) | The canonical ordering rule, the transaction model (optimistic apply + undo, deferred post-commit notification, non-reentrant mutation queueing), why `unordered_map` iteration order may never reach output, the snapshot section/digest scheme, what "equivalent state via different histories produces identical bytes" guarantees in practice, and two honestly-disclosed known limitations. |
| [`conformance.md`](conformance.md) | The task 11.1 coverage audit across all eleven native test areas, and the task 11.4 cross-subsystem "run twice, compare bytes/digest/checkpoints" determinism suite — including the precise, narrower scope the `EffectHandle`/`AbilitySpecId` allocation-order limitation leaves once effects and abilities exist. |
| [`budgets.md`](budgets.md) | Performance and allocation budgets for large-but-bounded tag/attribute/effect/ability/snapshot/protocol counts, backed by `ga_test_budgets.cpp`; three real findings (snapshot byte budget, transaction undo-op cap, attribute recompute locality) and their resolutions. |
| [`verification.md`](verification.md) | How to run every native/integration/export test suite locally (`tools/ga_verify.sh`) and in CI, what each suite proves and which spec requirement it maps to, and the current verified/planned status of every platform artifact (mirrors `release_manifest.json`). |
| [`distribution.md`](distribution.md) | The release-manifest artifact matrix and how a target earns `supported`, the symbols/stripping policy, the checksum workflow, the pre-1.0 API/protocol policy, unsupported-target behavior, and the task 12.5 gate that keeps the API and protocol pre-1.0. |
| [`../../../examples/gameplay_abilities/net/README.md`](../../../examples/gameplay_abilities/net/README.md) | The game-layer reference ENet direct-IP transport harness and bounded UDP LAN-discovery beacon/listener — explicitly **not** part of this addon's native core; documents why the game owns the peer, the loopback/direct-IP/discovery paths, and the discovery packet's security rules. |

## Suggested reading paths

- **First playable ability:** [how it works](how-it-works.md) ->
  [authoring](authoring.md) -> the
  [basic-combat example](../../../examples/gameplay_abilities/basic_combat/README.md).
- **Multiplayer ability:** [how it works](how-it-works.md) ->
  [integration](integration.md) -> [protocol](protocol.md) -> the
  [reference vertical slice](../../../examples/gameplay_abilities/slice/README.md).
- **Channel, charge, combo, or target confirmation:**
  [how it works](how-it-works.md) -> [tasks](tasks.md) ->
  [targeting](targeting.md) -> [hooks](hooks.md).
- **Content/debugging reference:** [API](api.md) for exact call shapes,
  [editor workflows](editor_workflows.md) for Inspector/dashboard actions,
  and [verification](verification.md) for the runnable suites.

## What is documented and implemented vs. still being built

Cross-referencing `docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/tasks.md`
as of this writing. **This section supersedes earlier revisions of this
file**, which were written while only sections 1–4 existed; effects,
abilities, the network bridge, and client prediction have since landed at
the native-core level, and `protocol.md`/`determinism.md`/`verification.md`
predate that work in places — read this section, not inferences from
those documents' own "what exists today" callouts, for the current state.

**Implemented and documented, at the native-core level, with native tests
(493 `GA_TEST` cases across `native/tests/*.cpp` at this revision, and
growing) and headless Godot integration tests
(`tests/gameplay_abilities/integration/`, `tests/gameplay_abilities/smoke/`,
`tests/gameplay_abilities/network/`):**

- Package/native foundation, SCons targets, ClassDB registration, API/
  protocol version constants and feature negotiation (section 1).
- Deterministic primitives: fixed-point, ticks, identifiers, runtime
  handles, transactions, and canonical snapshots (section 2).
- Gameplay tags, attributes, effects, and the full ability/component
  runtime — grants, activation, cost/cooldown/commit, cancellation,
  signals, snapshots, including `TagContainer` mutations participating in
  a caller-supplied transaction (sections 3–6; task 3.6).
- The full network protocol and server authority: handshake, activation
  commands, acknowledgement/rejection, ordered authoritative event
  streams, canonical snapshots, relevance filtering, and
  `GameplayAbilityNetworkBridge` itself, including the additional
  codec/fuzz/spoofing test pass (section 7; task 7.13).
- Client prediction and reconciliation at the native-core level
  (`ga::PredictingComponent`, `ga::PredictionJournal`,
  `ga::PredictionReconciler`, `ga::ServerTickEstimator` — section 8, with
  its own dedicated test coverage in `ga_test_prediction.cpp`), **now wired
  into the Godot layer** — `GameplayAbilityComponent`/
  `GameplayAbilityNetworkBridge` drive it for real (tasks 8.10, 8.11; see
  `api.md`'s "Prediction is wired into the Godot layer").
- Deterministic Ability Tasks for tick, gameplay-event, tag-query, logical
  input, authority, and typed-target waits, including hook continuation,
  snapshots, owner networking, prediction/replay, and restoration
  (`tasks.md`).
- Typed 2D/3D targeting for entity sets, points, directions, rays, and hit
  sets; schemas and providers; execution-owned sessions; coordinated atomic
  effect batches; correction/security; and the Godot world coordinator
  (`targeting.md`).
- Typed authority-only and prediction-safe hooks for both ability
  execution and effect calculation, bound to ClassDB with a Callable-based
  adapter so a game authors both families directly in GDScript
  (`GameplayAbilityComponent.bind_authority_hook`/`bind_prediction_safe_hook`,
  task 6.10; see `hooks.md`'s "GDScript exposure").
- Editor import/validation (`GameplayDefinitionValidator`,
  `GameplayDefinitionValidation` — task 9.2) and every authoring `Resource`
  class, including the ability and network-policy definition resources
  (`native/resources/*.h` — task 9.1; see `authoring.md`).
- The `runtime/` directory (task 9.1's remainder): `GameplayAbilityDefinitionBridge`
  (ability-Resource-to-Dictionary) and `GameplayNetworkPolicyBridge`
  (network-policy-Resource-to-bridge-setters), plus the logical cue
  adapter base and four HUD/animation/VFX/audio adapters (task 9.6; see
  `runtime/README.md`).
- The diagnostic inspector (task 9.3): `diagnostics/ga_diagnostic_overlay.gd`.
- The reference game-layer ENet harness and bounded LAN-discovery beacon
  (tasks 7.14, 7.15, 10.7).
- The full reference vertical slice — Dash, Poison, Stun, and Heal, run
  offline, over a loopback listen server, and over a loopback and real
  dedicated server with two clients, with genuine client-side prediction
  (`examples/gameplay_abilities/slice/`; tasks 10.1–10.8).
- Multi-process headless ENet conformance tests over isolated loopback
  ports for listen server, dedicated server, at least two clients, late
  join, resync, ownership spoofing, and target rejection
  (`tests/gameplay_abilities/network/run_multipeer_conformance.sh`, the
  `ga-multipeer` CI job; task 11.3's multi-peer requirement), and sanitizer/
  fuzz coverage of the protocol envelope (task 11.5).
- The determinism conformance suite and performance/allocation budgets
  (tasks 11.1, 11.2, 11.4, 11.6, 11.9, 11.10 — see `conformance.md`,
  `budgets.md`).
- CI jobs for native tests and the declared artifact matrix, and the
  release-manifest/distribution policy (tasks 12.1, 12.2, 12.4).
- Keeping the API/protocol pre-1.0 (task 12.5) and the formal
  proposal-approval gate (task 12.6). Ability Tasks and Typed Targeting move
  the additive API to `0.2.0` and wire protocol to `2`; both intentionally
  remain pre-1.0.
- This session's four documents: input/AI/replay integration and the
  input-agnostic activation contract (`integration.md`, task 9.4); the
  typed authority-only/prediction-safe hook contract with paired
  accepted/rejected examples (`hooks.md`, task 9.5); the complete public
  API reference (`api.md`) and resource-authoring guide (`authoring.md`),
  covering most of task 12.3's documentation list.

**Remaining work outside the Ability Task and Typed Targeting changes:**

- Task 11.7 (editor-load, extension-load, debug/release export, and
  network smoke tests for every advertised platform artifact) and task
  11.8 (a Linux x86_64 headless dedicated-server export and startup/session
  smoke test) remain open — the dedicated-server example scene and tooling
  now exist (`examples/gameplay_abilities/dedicated_server.tscn`,
  `tools/ga_dedicated_server.sh`), but the tasks themselves are not done.
- Foundation tasks 11.13/11.15 record an upstream Godot ENet teardown bug
  and a rare stress-only timing investigation. The conformance runner has a
  loud, marker-gated tolerance for the known post-success engine teardown
  crash; `GA_MULTIPEER_STRICT=1` restores unconditional failure.

`release_manifest.json` and `verification.md` remain the authoritative,
up-to-date source for exactly which platform artifacts have passed their
required smoke tests — do not infer platform support from this list.

## Global definition catalog and tag reactions (`add-global-tag-catalog-and-reactions-2026-07-25`)

Cross-referencing that change's own
`docs/spec/changes/add-global-tag-catalog-and-reactions-2026-07-25/tasks.md`,
sections 1–6, all complete as of this writing:

- **Section 1** — `GameplayDefinitionCatalog`, the
  `gameplay_abilities/default_definition_catalog` project setting,
  `GameplayAbilityComponent.definition_catalog`, catalog-vs-legacy
  mixed-config rejection, catalog validation, and canonical
  manifest/fingerprint contribution (`authoring.md`'s catalog sections).
- **Section 2** — the dashboard's Catalog and Migration tabs, catalog-backed
  Inspector reference pickers (hierarchical for tags, flat/grouped for
  everything else), orphan preservation, and undoable central
  create/rename/delete with usage reports (`editor_workflows.md`).
- **Sections 3–4** — the native `TagReactionRegistry` (cycle-safe, sealed)
  and the deterministic authority-only reaction runtime: predicate edges,
  canonical dispatch order, `WHILE_PRESENT` handle binding, the dynamic
  chain bound, and teardown discard (`reactions.md`).
- **Section 5** — the Godot adapter (`GameplayTagReactionDefinition`),
  authority-only network restriction, `WHILE_PRESENT` binding
  snapshot/restore without replay, protocol/manifest negotiation, and the
  full multi-process ENet coverage this change added on top of the
  foundation change's own network suite (`reactions.md`,
  `verification.md`).
- **Section 6** — this documentation, the basic-combat example's catalog
  conversion plus one demonstration ability per reaction mode
  (`examples/gameplay_abilities/basic_combat/README.md`), and the
  editor/usage walkthroughs above.

**One known, currently-open gap** carried forward from this change (not a
regression, not silently glossed over — see `authoring.md`'s "Known gaps"
and `reactions.md`'s "Observing reactions from GDScript"): the native
`TagReactionDiagnosticEvent` stream (`ga::AbilityComponent::add_tag_reaction_diagnostic_listener`)
and `active_tag_reaction_bindings()` are not yet wired to any
`GameplayAbilityComponent` GDScript signal/method — a game can still
observe a reaction firing indirectly, through the ordinary
`effect_lifecycle_changed`/`tag_changed` signals its effect application
already emits, but there is no direct "this reaction diagnostic fired"
signal yet.
