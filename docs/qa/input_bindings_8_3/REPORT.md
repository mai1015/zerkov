# Task 8.3 — input definitions, contexts, glyphs, and rebinding evidence

Status: implementation and repair evidence for the approved `8.3` task. This
packet does not mark the task ledger or truth specifications, and it does not
claim the unfinished gameplay consequence routing in task 5.7 or the
controls/rebinding UI port in task 8.10.

Implementation baseline: `bb0d281` (accepted CommonUI navigation). The branch
also merges the requested accepted-main checkpoint `c08a39b` (4.11 inventory
work) without changing that inventory UI in this task. Engine: Godot
`4.7.2.stable.official.ed1daf0bf`, headless Compatibility renderer.

## Outcome

`ZerkovInputActions` is the game-owned catalog. It declares stable
`common_ui/zerkov/...` gameplay and UI action IDs, bounded physical-binding
metadata, conflict groups, trigger/protection policy, explicit keyboard/mouse
and controller defaults, and logical glyph metadata. Every advertised movement
direction and the weapon-cycle wheel/controller affordances are projected into
CommonUI actions; no required default remains metadata-only. The five accepted
CommonUI framework IDs remain present; the game-owned Menu default moves to P
so Map retains M, and inventory/tasks use Start/right-stick rather than Godot's
Tab/Y/D-pad focus actions.

`ZerkovInputService` installs one validated `CommonUIInputConfig`, keeps the
native `CommonInputBindingRegistry` as the authoritative effective-binding
source, and publishes detached snapshots/canonical bytes. InputMap is only the
registry's namespaced projection; no gameplay state is read back from it.
Candidate action IDs, slots, policies, device-specific codes, glyph IDs,
request IDs, context leases and catalog sizes are bounded and fail closed.
Conflict preview uses the native registry; default policy is reject, with
explicit replace policy and native protection checks. The native persistence
format does not encode a conflict policy, so allow-duplicate is rejected before
mutation rather than creating an override that would fail on reload. Request IDs
are reserved before synchronous native mutation/publication, and context leases
are distinct caller-owned capabilities with project-owned priorities.

The service owns the project-specific Godot focus reservation gate. It validates
keyboard and joypad button/axis reservations from `ui_*` InputMap actions,
allows only the authored Back/Confirm framework overlaps, and rejects UI
defaults or rebinding candidates that would be swallowed by a focused Control.
Gameplay defaults remain in the gameplay context, which is suspended under UI
focus; their controller D-pad/stick metadata remains available to the gameplay
seam without being treated as a UI route.

Glyph publications delegate to the authoritative CommonUI resolver for
controller families, including axes, triggers, sticks and D-pad entries; the
game only bounds the returned metadata and supplies deterministic unknown
fallbacks.

CommonUI's existing screen contexts and layer lifecycle remain the production
route seam. The service adds only a bounded generation-scoped coordinator for
gameplay/UI/modal/developer context leases; modal priority suspends lower
leases, and stale tokens cannot release replacement contexts. UI inventory/map/
tasks/settings actions register on the active `ZScreen`; no second navigation
stack or gameplay consequence router was added. The F1 developer catalog path
remains unchanged.

Persistence remains the add-on's fixed `user://common_ui_bindings.json`
transaction. The service exposes no caller-selected path. Before CommonUI
install/reload, the service validates the selected target/backup/temp candidate
using the same bounds, device-kind, glyph-compatibility, collision and
protection policy as accepted rebinding; invalid candidates are guarded from
native load and leave current bindings unchanged. Native CommonUI performs
target/temp/backup atomic replacement and validates the complete document before
applying it. The current format is `2`; the add-on accepts only known,
schema-compatible older formats and rejects future/unknown formats, while
`definition_version=803` must match exactly. The service adds bounded request-ID
replay/idempotency and detached publications. Migration is deliberately
fail-closed: action/slot/protection schema changes require a new definition
version rather than guessing at old overrides.

The 8.3 repair changes no inventory scene, geometry, or layout. Visual
acceptance is 1920×1080 only.

The locked `addons/common_ui` destination was restored byte-for-byte to its
pinned snapshot; project-specific focus and modifier checks live only in the
game-owned service. The destination vendor check passes for all six locked
add-ons.

## Promoted contract coverage

`tests/zerkov_input_bindings_contract.gd` covers:

- stable IDs, gameplay/UI partition, bounded definitions, keyboard/mouse and
  controller defaults, all four movement directions, wheel weapon-cycle and
  controller weapon-cycle projections, glyph metadata, Xbox and unknown-family
  fallback;
- native config/action validation, conflict preview, reject/replace policy
  surface, unsupported duplicate-policy rejection before mutation,
  malformed/unknown/forged candidate rejection and policy/request bounds;
- detached effective bindings and recursive snapshot publication,
  deterministic canonical bytes, runtime registration validation;
- exact-1920 keyboard/controller UI routing through CommonUI;
- exact-1920 focused-button controller routing plus keyboard/joypad `ui_*`
  reservation rejection for defaults, rebinds and persisted overrides;
- context activation, bounded project priorities, distinct caller capabilities,
  peer-lease retention, priority suspension, modal gating, generation/stale
  token release, teardown invalidation and request replay/idempotency;
- fixed-path persistence commit/reload, known-format migration, corruption and
  stale-definition rejection, incompatible glyph/device rejection and live
  binding bytes unchanged.

The test saves and restores any pre-existing target/temp/backup candidates
before its corruption probe.

## Executed checks

| Evidence | Result |
| --- | --- |
| clean editor import (`godot --headless --editor --quit`) | exit 0; no `ERROR`, `SCRIPT ERROR`, parse, invalid, or fatal diagnostics |
| `zerkov_input_bindings_contract.gd` | `380` checks, `0` failures; exact-1920 runtime path |
| `common_ui_navigation_contract.gd` | `79` checks, `0` failures at exact 1920×1080 |
| `zerkov_screen_lifecycle_contract.gd` | `116` checks, `0` failures at exact 1920×1080 |
| `ui_smoke.gd` | `948` checks, `0` failures; route crawl at 1920×1080 |
| `inventory_loot_ui_4_11_contract.gd` | `88` checks, `0` failures at exact 1920×1080 |
| `addons/combined_addons_smoke.gd` | `155` checks, `0` failures |
| direct `CommonUIActionValidator` check | exit 0 |
| `tools/vendor_addons.py check --scope destination` | six pinned destination add-ons pass; CommonUI tree `94` files |
| strict approved-change validation | `Valid` |
| `git diff --check` | exit 0 |

No native desktop capture is claimed in this packet because the shared Godot
desktop was occupied by the independent visual reviewer. All UI/input/lifecycle
commands listed above use exactly 1920×1080 when a screen is involved. No
smaller-resolution, responsive, compact or deferred display suite was invoked,
and no smaller capture was generated. The exhaustive adaptive matrices remain
outside this task's evidence packet.

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

## Independent acceptance

Accepted on 2026-09-11 at immutable implementation head
`5159bdec6b119f46829b1d12dae7d34fe40de027` with no P0-P3 findings. The
independent pass verified deterministic duplicate-policy rejection, keyboard
and joypad `ui_*` collision protection, safe defaults, request reservation,
bounded context leases, glyph mappings, persistence, the byte-identical locked
CommonUI snapshot, and the retained Character inventory surface. Seventeen
permitted runs passed `2,612/0`, vendor tests passed `4/4`, import diagnostics,
strict spec validation, source hashes and diff checks were clean. Every UI run
was exact 1920×1080; no compact, responsive, alternate-size or deferred visual
suite ran.
