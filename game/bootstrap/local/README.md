# Local first-playable composition

`project.godot` now starts `local_game.tscn`, not the unbound UI host. Use the
locked standard Godot and the real native addons. The supported native validation
host is macOS. There is no .NET dependency for this flow.

## Starting the actual game

Open `project.godot` from the local-flow branch and use **Run Project (F5)**,
not Run Current Scene on `ui/main.tscn`. The UI scene on its own is an unbound
host for composition/QA; it does not own a ProfileStore or create a campaign.
The project entrypoint must be `res://game/bootstrap/local/local_game.tscn`.

The production menu displays **LOCAL SAVES**. Its primary action is **NEW LOCAL
GAME** when no save exists, then **CONTINUE LOCAL GAME** once a valid campaign
exists. Continuing never overwrites the campaign or issues starter gear again.
The slice currently has one campaign, not multiple save slots or a reset action.
A blocked load instead displays **LOCAL SAVE UNAVAILABLE** with the actual error.
Do not delete save files to bypass that diagnostic. **PRODUCTION DATA UNAVAILABLE**
is the separate UI-host lock, not a corrupt local campaign.

## Product path

Title → New local game / Continue → Bunker → existing loadout workspace →
persisted deployment → Sawmill → timed crate search / inventory loot / combat →
Road Gate extraction or death → committed summary → Bunker → another raid.
The main menu, Bunker, deployment, HUD, Tasks/Maps, pause and solo summary use
existing authored scenes with production-only bindings. Developer fixtures and
the original unbound-host tests remain separate; no F1 route forcing is required.

## Saves and deliberately narrow policies

- The fixed profile is `zerkov.profile.local`, stored through the existing
  `ProfileStore` at `user://zerkov/profile_store/profiles/`. Filenames derive
  from the profile identity. No backend, login, remote economy or cloud save.
- Explicit New local game issues starter equipment once. Existing, invalid or
  corrupt saves do not trigger replacement content. Normal launch does not accept
  an arbitrary save path. Native tests use a separate debug-only file namespace.
- Leaving the home inventory and deploying save the actual loadout. Deployment
  commits the unique raid identity and equipment escrow before starting simulation.
- Extraction retains the actual resulting loadout. Death/timeout applies the
  established secure-container retention plan. Abandonment/interrupted loading
  recovers from deployment escrow; newly acquired uncommitted loot is not restored.
- No mid-raid resume is advertised: the installed Level Task runtime has no
  verified persistence interface. An interrupted raid is recovered as abandoned.
- A failed settlement stays pending, blocks a new raid and offers Retry local
  save. Only a committed receipt becomes a final summary; retry does not replay
  combat, create a new settlement identity or grant the result a second time.
- Prototype policy for review: solo inventory, maps, menus and pause stop the
  local clock. Body health and survival resources recover on returning home.
  Historical damage/injuries stay in the receipt; lost equipment is not refilled.
  These are explicit local campaign policies, not multiplayer pause/health rules.
- Steam player-hosted co-op is a future integration target, not an enabled mode.
  The current build cannot host/join Steam lobbies. PvPvE and owned servers are
  outside this change. Never describe the readiness-inventory job as networking.

## Runtime ownership

`LocalGame` owns the local profile, Character binding, presentation epochs,
routing and lifetime. `LocalRaidSession` composes existing movement, navigation,
combat, Vision, AI, interaction, Level Task, progression and settlement owners.
`LocalRaidAIWorldPort` translates requests into the shared intent path, never
hands an authority to a brain, and delivers actual receipts/noise.

Every authoritative tick is followed by `RaidProgression.after_tick()` before
publishing. `LocalGameViews` converts closed values into the existing typed views;
`LocalFlowBinding` updates the designed controls in place without prototype
clocks or direct canonical mutation. Teardown releases consumers first, then the
exact `RaidAuthority` revokes its reserved Vision slot before disposing that owner.
The callback scanner caches only verified native property schemas, not safety
results; the original full scanner remains the differential-test reference.

## Controls

WASD move; mouse aim; left mouse fire; R reload; V melee; E search/open/extract;
I inventory; M map; J Tasks; Escape pause/back. Search must complete before E
opens the existing loot workspace. Ctrl-click or the existing inventory controls
transfer items. Road Gate requires three distinct searches and retained supplies.
Its five-second countdown is canonical; taking damage or leaving interrupts it.

## Reproduce and acceptance limits

```
python3 tests/tooling/test_registration_idempotence.py
python3 tools/run_local_flow_contracts.py --godot "$ZERKOV_GODOT"
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --native --execution
python3 tools/run_raid_progression_contracts.py --godot "$ZERKOV_GODOT" --native
```

The local runner drives actual Godot input through the production application.
It reads authored navigation/visible actor state to steer; it is not a blind
human test. Tick pacing and the save namespace are isolated. One write failure
is deliberately injected; all other file operations are real. Independent
verification processes compare the committed profile fingerprint. No teleports,
fixture profile, direct health damage or manufactured terminal outcome substitutes
for gameplay in this flow. Raw diagnostics belong in CI artifacts, not source.

Functional correctness is not real-time readiness: the first complete debug-host
extraction took roughly 340 seconds for 1,365 driven simulation ticks. This is
well outside the 60 Hz budget and needs a dedicated performance pass. Do not
call this release-ready, use a larger timeout as a performance fix, or cache
mutable callback-safety decisions to hide that cost.

Task mapping: death-race coverage addresses 5.10; the visible canonical clock
addresses 7.3; live HUD, Tasks/Maps and deployment/receipt binding address
8.5/8.7/8.8. Review those implementations with their native evidence before
checking acceptance. No claim of ten consecutive extract/death cycles, complete
controller navigation, native combat readability, VFX/audio completion, human
visual approval, a hit-reaction clip, or Steam support is made here.

## Known combat-policy limit

The current health policy kills at zero head/thorax health, but caps damage in
other body zones at zero without transferring excess damage to a lethal zone.
A stationary attacker can therefore keep hitting an already-destroyed limb
without killing its target. This remains a gameplay/balance limitation; this PR
does not silently change the accepted damage/bleed policy to make a test pass.
The lethal-flow regression explicitly faces the visible attacker through actual
mouse input, instead of inheriting the cursor position from the previous menu.
It neither sets facing directly nor changes health, damage, AI or the outcome.
