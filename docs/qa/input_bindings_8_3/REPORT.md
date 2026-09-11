# Task 8.3 — input definitions, contexts, glyphs, and rebinding evidence

Status: implementation evidence for the approved `8.3` task. This packet does
not mark the task ledger or truth specifications, and it does not claim the
unfinished gameplay consequence routing in task 5.7 or the controls/rebinding
UI port in task 8.10.

Baseline: `bb0d281` (accepted CommonUI navigation; branch
`codex/input-bindings-8-3`). Engine: Godot `4.7.2.stable.official.ed1daf0bf`,
headless Compatibility renderer.

## Outcome

`ZerkovInputActions` is the game-owned catalog. It declares stable
`common_ui/zerkov/...` gameplay and UI action IDs, bounded physical-binding
metadata, conflict groups, trigger/protection policy, explicit keyboard/mouse
and controller defaults, and logical glyph metadata. The five accepted
CommonUI framework IDs remain present; the game-owned Menu default moves to P
so Map retains M.

`ZerkovInputService` installs one validated `CommonUIInputConfig`, keeps the
native `CommonInputBindingRegistry` as the authoritative effective-binding
source, and publishes detached snapshots/canonical bytes. InputMap is only the
registry's namespaced projection; no gameplay state is read back from it.
Candidate action IDs, slots, policies, codes, glyph IDs, request IDs and
catalog sizes are bounded and fail closed. Conflict preview uses the native
registry; default policy is reject, with explicit replace/allow-duplicate
options and native protection checks.

CommonUI's existing screen contexts and layer lifecycle remain the production
route seam. The service adds only a bounded generation-scoped coordinator for
gameplay/UI/modal/developer context leases; modal priority suspends lower
leases, and stale tokens cannot release replacement contexts. UI inventory/map/
tasks/settings actions register on the active `ZScreen`; no second navigation
stack or gameplay consequence router was added. The F1 developer catalog path
remains unchanged.

Persistence remains the add-on's fixed `user://common_ui_bindings.json`
transaction. The service exposes no caller-selected path. Native CommonUI
performs target/temp/backup atomic replacement, validates the complete document
before applying it, and leaves current bindings unchanged on malformed or
unknown entries. The current format is `2`; the add-on accepts only known,
schema-compatible older formats and rejects future/unknown formats, while
`definition_version=803` must match exactly. The service adds bounded request-ID
replay/idempotency and detached publications. Migration is deliberately
fail-closed: action/slot/protection schema changes require a new definition
version rather than guessing at old overrides.

No inventory scene, geometry, or layout was changed. Visual acceptance is
1920×1080 only.

## Promoted contract coverage

`tests/zerkov_input_bindings_contract.gd` covers:

- stable IDs, gameplay/UI partition, bounded definitions, keyboard/mouse and
  controller defaults, glyph metadata, Xbox and unknown-family fallback;
- native config/action validation, conflict preview, reject/replace policy
  surface, malformed/unknown/forged candidate rejection and policy/request
  bounds;
- detached effective bindings and recursive snapshot publication,
  deterministic canonical bytes, runtime registration validation;
- exact-1920 keyboard/controller UI routing through CommonUI;
- context activation, priority suspension, modal gating, generation/stale
  token release, request replay/idempotency;
- fixed-path persistence commit/reload, known-format migration, corruption and
  stale-definition rejection with live binding bytes unchanged.

The test saves and restores any pre-existing target/temp/backup candidates
before its corruption probe.

## Executed checks

| Evidence | Result |
| --- | --- |
| clean editor import (`godot --headless --editor --quit`) | exit 0; no `ERROR`, `SCRIPT ERROR`, parse, invalid, or fatal diagnostics |
| `zerkov_input_bindings_contract.gd` | `285` checks, `0` failures |
| `common_ui_navigation_1080_regression.gd` | `94` checks, `0` failures at exact 1920×1080 |
| `ui_smoke.gd` | `945` checks, `0` failures; route crawl at 1920×1080 |
| `utility_smoke.gd` | `24` checks, `0` failures at 1920×1080 |
| `raid_smoke.gd` | `29` checks, `0` failures at 1920×1080 |
| `bunker_smoke.gd` | `0` failures at 1920×1080 |
| `inventory_smoke.gd` | `21` checks, `0` failures at 1920×1080 |
| `addons/combined_addons_smoke.gd` | `155` checks, `0` failures |
| strict approved-change validation | `Valid` |
| `git diff --check` | exit 0 |

No native desktop capture is claimed in this packet because the shared Godot
desktop was occupied by the independent visual reviewer. No smaller-resolution
visual, input, or lifecycle run is acceptance evidence. The existing
`common_ui_navigation_contract.gd` and exhaustive lifecycle/adaptive matrices
were not rerun because they intentionally resize below 1920×1080; their
accepted 8.2 evidence remains outside this task's evidence packet.

## Boundaries

- Gameplay action consequences and authoritative intent routing remain task
  5.7. The gameplay catalog is definitions-only here.
- Controls/rebinding presentation and exhaustive modal/focus/rebinding
  regression port remain task 8.10. The existing controls fixture is not
  silently presented as the new registry's source of truth.
- No physical controller or native visual capture was available in this
  headless run; synthetic keyboard/controller events prove CommonUI routing,
  while device profiles and deterministic glyph fallback are covered as pure
  catalog/service contracts.
