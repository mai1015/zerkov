# Merged-main game-cycle audit — 2026-09-15

## Verdict

**The raid-cycle components pass their native contracts, but the normal player-facing game cycle is not connected.** Zero complete player-driven cycles were executed. The first reproducible blocker is the main menu immediately after the title screen, before bunker/profile selection or deployment.

Audited production revision: `cb8bc50e72b631664c9f1fb2a59ee5e84249fbae`.
Engine: `4.7.2.stable.official.ed1daf0bf`.
Combined-native execution: macOS arm64 GitHub runner, full checkout and its actual six vendored extensions. Every engine test requested exact 1920x1080. These runs were headless: no graphical screenshots, controller playtest or human playtest are claimed.

The audit branch changes only validation code/workflows and this report. Production `game/`, `ui/`, `addons/`, `assets/` and `project.godot` were compared against the exact audited main commit and are unchanged. Fixtures were not enabled to manufacture a playable menu.

## 1. Actual normal-launch input observation

Workflow: https://github.com/mai1015/zerkov/actions/runs/35022690111
Artifact: `normal-launch-input-observation`, ID `10417918796`.
Probe source revision: `23162059d13350eb2aedcb5203dd0e0fe4985f27` (same production files as audited main).

The probe instantiated `ui/main.tscn` with its default title route and no injected profile, presentation provider, character runtime or fixture provider. It dispatched actual Godot keyboard/mouse input via the root viewport; it did not directly navigate to the desired destination or call menu callbacks.

| Step | Observation |
| --- | --- |
| Normal scene boot | `title`; input accepted; QA mode false; prototype-fixture mode false; no fixture provider |
| Press Enter | `main_menu`; input not accepted; production state locked; typed presentation view not ready |
| Visible main-menu status | `PRODUCTION DATA UNAVAILABLE`, `STATE UNBOUND`, `DIAGNOSTIC UI_SERVICES_NOT_INJECTED_BUNKER` |
| Click the visible Return to Title button | Returns to `title` via the existing UI/input path |
| Press Enter again | The same locked main menu and diagnostic; no fixture fallback |

```text
NORMAL_LAUNCH_PROBE_RESULT checks=11 failures=0 completed_game_cycles=0 game_cycle_complete=false
engine_exit=2
first_blocker=main_menu_missing_authoritative_presentation
```

The 11 passing checks establish that this blocker was reproduced correctly. **They do not establish a passing game cycle.** The workflow deliberately ends non-green (exit 2) when the cycle is unavailable. The probe covers the launch boundary; once that boundary is connected, it must be extended to actually drive later stages rather than label an unlocked menu a complete cycle.

## 2. Existing contracts rerun on exact main

Workflow: https://github.com/mai1015/zerkov/actions/runs/35022199187
Full native job: `104560401083`.
Artifact: `merged-main-native-flow-results`, ID `10418340866`.
All nine independently executed commands passed, with zero matched engine/script error diagnostics and no timeouts. Raw logs and command-level results are retained.

| Test | Observed result |
| --- | --- |
| Repository exact-1080 source policy | `FIRST_PLAYABLE_1080_GATE passed=true` |
| Progression runner unit tests | 8 Python tests passed |
| Full-checkout editor import | Exit 0, no script/extension-load errors |
| Raid progression logic | `311/0` checks, twice |
| Native task/inventory/combat/progression composition | `NATIVE_RAID_PROGRESSION_RESULT checks=446 failures=0` |
| Actual-file restart: prepare / recover / verify | `9/0` in each of three separate Godot processes; cleanup `5/0` |
| ProfileStore | `PROFILE_STORE_RESULT checks=527 failures=0` |
| Six-add-on smoke | `ADDON_SMOKE_RESULT checks=155 failures=0` |
| Production unavailable-state regression | `111/0`, confirms missing-service routes stay locked |
| Main-scene QA smoke | 28 screens, zero missing/capture errors; headless, so no captures |
| UI route regression | `UI_TEST_COMPLETE checks=958 failures=0` |
| Screen lifecycle | `116/0`, 28 routes at exact 1920x1080 |

Progression run completion: `RAID_PROGRESSION_RUNNER_COMPLETE mode=native`.
The native workflow's nine commands include several subcontracts; table rows are not nine independent full game sessions. Repeated assertion totals are not distinct gameplay scenarios.

Separately, the existing isolated progression runner was executed in the local Linux container using the exact pinned engine: progression `311/0` twice and ProfileStore `527/0`, with a clean completion marker. That local mode uses the documented test ports, not the full six native extensions. The macOS run above is the evidence for the combined native checkout.

### What the native progression test really proves

The existing native test uses real Inventory, Level Task, combat/health composition, interaction policy and RaidAuthority. It verifies persisted deployment; three distinct timed searches; required possession of the supply item; extraction eligibility; interruption when the item is lost; explicit cancellation; one terminal extraction; failed settlement write/retry; and an immutable committed summary.

It also checks native death-loss planning (secured bandages retained, unsecured weapon/ammunition lost). Pure progression tests cover terminal precedence and the broader persistence failure matrix. The separate restart runner uses actual files in a fresh test namespace and three distinct processes; the recovered and verified profile fingerprints match:

```text
bac1ce21cb601962b8d703db7dd1599ba4b298d9c70b18b8e5b3b452b4d2694a
```

This is not an end-to-end player run. The native test seeds a test loadout, places the actor at authored Sawmill anchors using its movement owner's fixture placement method, and transfers the objective through native commands from the test host. It does not walk the player through the normal deployment, loot UI, results screen and next-raid controls. Its main extract/settlement scenario uses an explicit fake filesystem for failure injection; the separate restart scenario supplies actual-file evidence. No actual user save is modified.

## 3. Integration findings

### P0 — normal menu has no product composition

`project.godot` starts `res://ui/main.tscn`. In `ui/main.gd`, `_configure_presentation_provider()` constructs an `UnavailableUIPresentationProvider` unless a real provider was injected; normal startup creates the Character composition without authority dependencies. The new deployment/progression services are not constructed by this launch path.

`ui/core/screen.gd::_should_render_locked_state()` deliberately keeps non-self-managed production routes locked. Injecting a view alone is therefore insufficient: product-screen binding must also be implemented. Do not remove these locks or enable `--prototype-fixtures` as a purported game-cycle fix.

### P1 — deployment and results are not connected to the domain cycle

The authored deployment screen and shared frontflow actions retain a fixture timer (`frontflow_deploy_percent`, +8 per timer step) that navigates to the HUD in explicit preview mode. It is not a call to `RaidDeployment.begin()`. The normal UI currently cannot create/select a real profile, commit equipment escrow, construct a raid composition, publish its HUD or render a final settlement through the normal flow.

### P1 — polished Northline remains a review scene

The large Northline scene still instantiates the inspection walker, not a RaidAuthority-bound gameplay actor. Its markers/routes/collision walkthrough are environment evidence. The actual Supply Run graph explicitly names three Sawmill crate IDs and `zerkov.extract.sawmill.road_gate`; a Northline extraction marker does not automatically satisfy that contract. Production deployment must bind the chosen map's actor, collision/navigation/vision, world inventories, targets and extraction policy explicitly.

### P1 — a second raid is not covered by live health restoration

The progression README explicitly says the receipt persists `project.last_raid_health`, but does not rehydrate the next live GAS actor. Between-raid health restoration/reset must be defined and wired before a second real raid can be certified. A successful profile restart test is not evidence of restored live health or a functioning Continue button.

### P2 — title still presents authored account/service text

The actual no-fixture title displays `ONLINE`, `EU-WEST · 34 ms`, `v1.1.2` and `SIGNED IN AS OAK_JHONSON`. These are authored display strings, not verified account, networking or latency information. They should become honest offline/local status or real provider-backed data during product-shell integration.

### Checklist drift

The original playable-raid `tasks.md` still leaves most task-7 and UI deployment/summary items unchecked. There is newer code and working native evidence, so neither the old checklist nor green component CI alone answers end-to-end readiness. Preserve the distinction between implementation, integration and player-flow acceptance.

The earlier eight repository policy findings are **not reproduced on this main revision**: the actual main source-policy command now passes. Historical failures should not be carried forward as current defects.

## 4. Next acceptance slice

Connect one offline application/raid composition root, rather than add more map polish or bypass unavailable-state checks:

1. Load/create a real versioned profile; define explicit new-profile starter content; bind Bunker/Character views and deployment intent.
2. Persist deployment before enabling play; mount the selected map; connect one authoritative movement/combat/interaction/task/input pipeline; publish HUD snapshots after progression `after_tick()` closes the canonical tick.
3. Complete extraction or death through `finish()`; show only a committed receipt; return to the same profile/bunker; reconstruct the next actor and loadout according to the defined health rule.
4. Prove actual input-driven extraction and death cycles, then close/relaunch and compare inventory/profile receipts. Include interrupted extraction, duplicate completion, postcommit acknowledgement loss and a second deployment. No F1, forced routes, fixture loadouts or teleport shortcuts in the end-to-end acceptance run.

No full-cycle completion, graphical playtest, release readiness or production fixes are claimed by this audit.
