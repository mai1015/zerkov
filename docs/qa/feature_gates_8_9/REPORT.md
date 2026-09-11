# Task 8.9 — feature-gated meta-action evidence

Status: implementation candidate only. Task 8.9 remains unchecked pending
independent review. human_approval: false.

Implementation base: ebb003ce068d4621a49af9614be136a149580dd8.
Accepted current main merged before final sealing:
1b201cb031ec174dad616334b302e22cc7a744c5.
Engine: Godot 4.7.2.stable.official.ed1daf0bf; native Compatibility renderer
for the evidence frame and headless Compatibility for source/provider/UI
regressions.

## Outcome

ZUIFeatureGateView is the immutable, typed capability metadata contract for
the five approved action ids: bunker, crafting, friends, insurance, and
marketplace. It exposes LOCKED, PROTOTYPE, and AVAILABLE states with a stable
display label, diagnostic reason, generation metadata, and detached snapshot.
The provider publishes generation-scoped locked values using the accepted Task
8.11 unavailable pattern; stale, replaced, and released leases cannot expose
retired capability truth.

ZUIContext.feature_gate() returns PROTOTYPE only for an explicit fixture
provider and returns typed LOCKED truth for production composition. No
production app.state access, fake production data, or new service was added.
The existing authored screens and CommonUI navigation/focus graph remain in
place.

ZScreen now annotates retained controls with typed status metadata and
truthful PROTOTYPE ONLY/LOCKED tooltips, and guards callbacks again at
execution time. Bunker stations/build/session/privacy/deploy, crafting
filters/recipes/queue, friend joins/codes/invites/messages/privacy, insurance
confirmation, marketplace sell/market affordances, and world/save setup
actions are covered. The shared NavigationChrome Insurance affordance also
starts with truthful locked metadata before its owning screen binds.

## Focused regression contract

tests/presentation/feature_gates_8_9_contract.gd is pinned to
Vector2i(1920, 1080) and covers:

- typed provider publication for all five ids, unknown-id rejection,
  generation replacement, stale leases, teardown and explicit diagnostics;
- unchanged 28-route CommonUI catalog with no replacement marketplace route;
- fixture-only prototype annotations/tooltips for bunker, crafting, friends,
  insurance and marketplace controls;
- callback guards that retain CommonUI focus inside the active authored screen;
- production route unavailable state and locked bunker/friend/insurance/
  marketplace behavior;
- exact logical root sizing and optional native evidence capture.

## Visible gate evidence contract

tests/presentation/feature_gates_8_9_visual_evidence.gd is an explicit QA
runner, not a production fallback. It enables the existing app's fixture
provider, mounts the authored `bunker`, `crafting`, `join_friend`,
`summary_solo`, and `inventory` routes through CommonUI, focuses one real
control on each route, and triggers the screen's real toast path. For every
one of the five typed action ids it asserts the visible control's
`z_feature_action`, `z_feature_status`, `z_feature_status_label`, and tooltip,
then asserts that the visible toast names the action and says `PROTOTYPE ONLY`.
Native runs save the five full-size source frames and a contact sheet derived
only from those frames; the runner does not create a replacement screen,
populate production state, or bypass the existing focus graph.

## Executed checks

| Evidence | Result |
| --- | --- |
| strict approved-change validation | Valid |
| editor import/class registration | exit 0 |
| static first-playable scope contract | 2 tests, 0 failures |
| Task 8.9 provider/action/route/focus contract | 54/0 headless; 57/0 native capture |
| Task 8.9 visible gate evidence contract | 37/0 headless assertions; 55/0 native assertions, 5 frames |
| Task 8.11 provider/source contract | 57/0 |
| read-only view contracts | 115/0 |
| CommonUI navigation | 79/0 |
| CommonUI navigation 1080 regression | 94/0 |
| CommonUI integration | 76/0 |
| UI route smoke | 948/0 |
| UI composition | 103/0 |
| bunker / raid smoke | 21/0 and 29/0 |
| Character composition / UI binding | 22/0 and 65/0 |
| inventory loot UI / inventory smoke | 88/0 and 21/0 |
| utility smoke | 24/0 |
| screen lifecycle | 116/0; geometry hash unchanged |
| source/evidence hashes | shasum -a 256 -c sources.sha256: all OK |
| git diff --check | exit 0 |

Every Godot invocation used the exact approved viewport argument:

    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --editor --quit
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/utilities/settings.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/utilities/controls.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/raid/pause.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/raid/summary_squad.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/frontflow/frontflow_actions.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/frontflow/saves.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://ui/screens/frontflow/main_menu.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_contract.gd -- --capture-path=res://docs/qa/feature_gates_8_9/feature_gates_headless_1920x1080.png
    /opt/homebrew/bin/godot --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_contract.gd -- --capture-path=res://docs/qa/feature_gates_8_9/feature_gates_1920x1080.png
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --check-only --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd
    /opt/homebrew/bin/godot --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd -- --capture-dir=res://docs/qa/feature_gates_8_9
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/ui_state_8_11_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/view_contracts_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_navigation_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_navigation_1080_regression.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_integration_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/ui_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/ui_composition_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/bunker_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/raid_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/character_presentation_composition_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/character_ui_binding_8_6_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/raid/inventory_loot_ui_4_11_contract.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/inventory_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/utility_smoke.gd
    /opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/zerkov_screen_lifecycle_contract.gd

The headless capture command reports
HEADLESS_CAPTURE_SKIPPED dummy renderer has no native framebuffer; it does
not create an artifact. The native command prints
NATIVE_FRAMEBUFFER_SIZE=(1809, 1018) logical=1920x1080 on this macOS host.
The runner asserts the logical root is exactly 1920×1080 and uses nearest-
neighbor sampling only to write the logical evidence image at the required
1920×1080 dimensions; it renders no alternate layout or viewport.

## Native evidence

[feature_gates_contact_sheet_1920x1080.png](feature_gates_contact_sheet_1920x1080.png)
is the exact-1920 QA overview made from the five native source frames. Its
top row is the authored Bunker, Crafting, and Join Friend UI; its bottom row is
the authored Summary Solo and Character Inventory UI. Each tile retains the
real focused control and the real `PROTOTYPE ONLY` toast. The five full-size
source frames are the primary evidence when reading control metadata and
toast text: [bunker](feature_gate_bunker_1920x1080.png),
[crafting](feature_gate_crafting_1920x1080.png),
[friends](feature_gate_friends_1920x1080.png),
[insurance](feature_gate_insurance_1920x1080.png), and
[marketplace](feature_gate_marketplace_1920x1080.png).

[feature_gates_1920x1080.png](feature_gates_1920x1080.png) remains the native
Compatibility-renderer production missing-service reference. It shows the
existing centered unavailable card, explicit diagnostic truth, and no sample
profile or fake production data; it is intentionally separate from the
fixture-provider gate sheet above. That PNG is exactly 1920x1080 and has
SHA-256 56c177ede335d4f66a9d295d65a44df92e6d4bc86c7d0b8daec784765c63f4f8.
The six new visual artifacts and all source hashes are recorded in
[sources.sha256](sources.sha256).

The native runner logged the actual macOS Compatibility framebuffer as
`(1809, 1018)` while the logical Godot root remained exactly `1920x1080`.
It nearest-neighbor resampled only the captured image to the required
1920x1080 artifact dimensions; no alternate layout or viewport was rendered.

## Diff and route audit

The implementation commit touched 30 paths because the same typed guard must
be attached at every existing owner of the five approved actions: the provider
and context contract, shared CommonUI Insurance chrome, the five-file Bunker
family, four front-flow friend/world setup files, six raid/character callback
owners, and four utility Insurance owners, plus the typed view, focused
contract, and QA artifacts. The visual-evidence follow-up adds one test script
and six derived PNG artifacts only.

The source diff contains no `.tscn` geometry or layout changes, no route catalog
change, no marketplace route, no inventory hierarchy replacement, no service,
and no production fixture data. Every changed callback is either a gate
annotation/tooltip or an execution-time guard for bunker, crafting, friends,
insurance, or marketplace; unrelated callbacks retain their existing route,
state, and focus behavior. The unchanged 28-route catalog, no-marketplace
assertion, CommonUI navigation, composition, smoke, and lifecycle regressions
provide the non-gated route and focus audit.

No compact, responsive, 1600, 1280, 960, or other alternate-size command or
capture was run or regenerated.

## Scope held

This candidate adds no bunker, crafting, friends, insurance, marketplace,
inventory, persistence, or replacement UI service. It keeps all feature
actions fixture-only or locked until an owning service publishes approved
authoritative capability truth. It does not edit the task ledger checkbox or
claim Task 8.9 acceptance.
