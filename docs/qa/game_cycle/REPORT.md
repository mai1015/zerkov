# Merged-main game-cycle audit — 2026-09-15

## Verdict and revisions

**The raid-cycle components pass their native contracts, but the normal player-facing game cycle is not connected.** Zero complete player-driven cycles were executed. The first reproducible blocker is the main menu immediately after the title screen, before bunker/profile selection or deployment.

Executed production revision: `cb8bc50e72b631664c9f1fb2a59ee5e84249fbae`.
Engine: `4.7.2.stable.official.ed1daf0bf`.
Combined-native execution: macOS arm64 GitHub runner, full checkout and its actual six vendored extensions. Every engine test requested exact 1920x1080. These runs were headless: no graphical screenshots, controller playtest or human playtest are claimed.

During this audit, main advanced to `bfae2bd69c6ec3f5efd369bd7858fa629f7b9e05` through PR #15. The GitHub comparison from the executed revision changes only `docs/spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md` (22 checkbox updates); production code and assets are identical. The previously stale task-7 checklist is now updated. This documentation change does not remove the runtime blocker below, and no rerun of changed gameplay is implied.

The audit branch changes only validation code/workflows and this report. Production `game/`, `ui/`, `addons/`, `assets/` and `project.godot` were compared against the exact executed main commit and are unchanged. Fixtures were not enabled to manufacture a playable menu.

## 1. Actual normal-launch input observation

Workflow: https://github.com/mai1015/zerkov/actions/runs/35022690111
Artifact: `normal-launch-input-observation`, ID `10417918796`.
Probe revision: `23162059d13350eb2aedcb5203dd0e0fe4985f27`, with unchanged production files.

The probe instantiated `ui/main.tscn` with its default title route and no injected profile, presentation provider, character runtime or fixture provider. It dispatched actual Godot keyboard/mouse events through the root viewport; it did not force a route or call menu callbacks directly.

| Step | Observation |
| --- | --- |
| Normal scene boot | `title`; input accepted; QA false; prototype-fixture mode false; no fixture provider |
| Press Enter | `main_menu`; input rejected; production state locked; typed presentation view not ready |
| Visible main-menu status | `PRODUCTION DATA UNAVAILABLE`, `STATE UNBOUND`, `DIAGNOSTIC UI_SERVICES_NOT_INJECTED_BUNKER` |
| Click visible Return to Title | Returns to `title` through the existing UI/input path |
| Press Enter again | Identical locked menu and diagnostic, without fixture fallback |

```text
NORMAL_LAUNCH_PROBE_RESULT checks=11 failures=0 completed_game_cycles=0 game_cycle_complete=false
engine_exit=2
first_blocker=main_menu_missing_authoritative_presentation
```

The 11 passing checks establish successful reproduction, **not a passing game cycle**. The workflow intentionally ends non-green when the cycle is unavailable. The probe only covers this launch boundary. Once it is connected, later input-driven stages must be added; an unlocked menu alone must never count as a complete cycle.

## 2. Existing contracts rerun on exact main

Workflow: https://github.com/mai1015/zerkov/actions/runs/35022199187
Full native job: `104560401083`.
Artifact: `merged-main-native-flow-results`, ID `10418340866`.
All nine independently executed commands passed with no matched engine/script error diagnostics or timeouts. Raw logs and command-level results are retained.

| Test | Observed result |
| --- | --- |
| Repository exact-1080 source policy | `FIRST_PLAYABLE_1080_GATE passed=true` |
| Progression runner unit tests | 8 Python tests passed |
| Full-checkout editor import | Exit 0, no script/extension-load errors |
| Raid progression logic | `311/0`, twice |
| Native task/inventory/combat/progression composition | `446/0` |
| Actual-file restart: prepare / recover / verify | `9/0` in each of three distinct Godot processes; cleanup `5/0` |
| ProfileStore | `527/0` |
| Six-add-on smoke | `155/0` |
| Production unavailable-state regression | `111/0`, confirms missing-service routes stay locked |
| Main-scene QA smoke | 28 screens, zero missing/capture errors; headless, so no captures |
| UI route regression | `958/0` |
| Screen lifecycle | `116/0`, 28 routes at exact 1920x1080 |

Completion marker: `RAID_PROGRESSION_RUNNER_COMPLETE mode=native`.
Some of the nine commands contain multiple subcontracts; these are not nine complete game sessions. Repeated assertions are not distinct gameplay scenarios.

The existing isolated progression runner also ran locally on Linux with the exact engine: progression `311/0` twice and ProfileStore `527/0`. That local mode uses its documented test ports, not six native extensions. The macOS run is the combined-native evidence.

### What the native progression test really proves

The native contract uses real Inventory, Level Task, combat/health composition, interaction policy and RaidAuthority. It checks persisted deployment; three distinct timed searches; current possession of the supply item; extraction eligibility; interruption after item loss; explicit cancellation; one terminal extraction; settlement write failure/retry; and a committed immutable summary.

It separately tests native death-loss planning: secured bandages remain and unsecured weapon/ammunition are lost. Pure progression tests cover terminal precedence and the broader persistence failure matrix. The restart runner uses actual files in a unique test namespace and three distinct processes. Recovered and verified profile fingerprints match:

```text
bac1ce21cb601962b8d703db7dd1599ba4b298d9c70b18b8e5b3b452b4d2694a
```

This is not a player-driven end-to-end run. The native contract seeds a test loadout, places the actor at Sawmill anchors through the movement owner's fixture-placement method and transfers the objective through native commands from the test host. It does not exercise normal deployment controls, player traversal, loot UI, results routing or a second raid. Its extract/settlement scenario uses an explicit fake filesystem for failure injection; the separate restart scenario supplies actual-file evidence. No actual user save was modified.

## 3. Integration findings

### P0: No product composition behind normal launch

`project.godot` starts `ui/main.tscn`. `ui/main.gd::_configure_presentation_provider()` constructs an `UnavailableUIPresentationProvider` unless a real provider is injected. Normal startup also creates Character presentation without authority dependencies. The new deployment/progression services are not constructed by this launch path.

`ui/core/screen.gd::_should_render_locked_state()` deliberately locks non-self-managed production routes. Injecting a view alone is insufficient: product-screen binding also needs implementation. Removing these guards or enabling prototype fixtures would hide the gap rather than complete the game.

### P1: Deployment and results are not wired to the domain cycle

The authored deployment controller/shared actions retain a fixture timer (`frontflow_deploy_percent`, +8 per timer step) that navigates to the HUD in explicit preview mode. This is not `RaidDeployment.begin()`. The normal flow does not yet select a real profile, commit equipment escrow, construct a live raid, publish its HUD, then render the final receipt and return to that profile.

### P1: Northline is still a review scene, not the native task map

The large Northline scene instantiates an inspection walker, not an authority-bound gameplay actor. Its markers and collision walkthrough are environment evidence. The real Supply Run graph names three Sawmill crate IDs and `zerkov.extract.sawmill.road_gate`. Northline needs explicit production actor, collision/navigation/vision, world-inventory, target and extraction bindings; its review exit markers are not active extraction policy.

### P1: Second-raid live health restoration remains open

The progression README explicitly states that receipts persist `project.last_raid_health` but do not rehydrate the next live GAS actor. Between-raid restoration/reset must be defined and wired before a second real raid is certified. A persisted health summary and a successful restart contract do not prove restored live health or a working Continue button.

### P2: Authored title account/service labels

The no-fixture title actually displays `ONLINE`, `EU-WEST · 34 ms`, `v1.1.2` and `SIGNED IN AS OAK_JHONSON`. These are authored strings, not verified account/network/latency data. Replace them with honest offline/local status or real provider data during shell integration.

### Current policy and checklist status

The original task checklist was stale at the executed revision; PR #15 corrected its delivered task-7/AI/art flags while the audit ran. Implementation, integration and player-flow acceptance must still remain distinct. The earlier eight repository-policy findings are not reproduced on executed main: the full source-policy command now passes. Historical failures are not current defects.

## 4. Next acceptance slice

Connect one offline application/raid composition root, without another gameplay implementation or bypassing unavailable-state checks:

1. Load/create a versioned profile, define explicit new-profile starter content, bind Bunker/Character views and deployment intent.
2. Persist deployment before enabling play; mount the chosen map; connect the existing authoritative movement/combat/interaction/task/input owners; publish HUD data after `after_tick()` closes the canonical tick.
3. Finish extraction/death through `finish()`, display only a committed receipt, return to the same profile and reconstruct the next actor/loadout under the defined health rule.
4. Prove input-driven extraction and death cycles plus close/relaunch, inventory/receipt comparisons and second deployment. Include extraction interruption, duplicate completion and acknowledgement loss. No F1, forced route, fixture loadout or teleport shortcut may substitute for these end-to-end acceptance runs.

No full-cycle completion, graphical playtest, release readiness or production fix is claimed by this audit.
