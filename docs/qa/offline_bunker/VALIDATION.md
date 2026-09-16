# Offline bunker MVP — verified execution

## Result and exact revision

The approved pre-raid MVP now runs through normal startup into the authored
bunker, edits real native inventory, saves locally, and restores it through
Continue in an independent Godot process. This is not a completed raid cycle.

Verified production/source revision: `83cfcb6a5d24cd72cf6acb8951ee92ae5ad88c55`.
Integrated main baseline: `f1e338ed509f253dba85a4c0e0b0b8bbf089783f`.
Final workflow: https://github.com/mai1015/zerkov/actions/runs/35038486063
Native job: `104612837223`; source-review job: `104612837423`.
Artifact: `offline-bunker-native-results`, ID `10424182040`.
Archive SHA-256: `d32d5859f9eefcfeff59bd4a5f5436d52db62fd31c1af6265c65fefbb9d34e69`.

This report and the task/capture ledger are a subsequent documentation-only
commit. They do not alter the production scripts, tests, registered runner hashes,
assets or workflows that were executed at the verified revision.

## Full native application results

The actual full repository and its six native add-ons ran on the macOS GitHub
runner using standard Godot `4.7.2.stable.official.ed1daf0bf`. The launcher checks
that exact version against the repository lock. No add-on stubs, fixture provider,
forced route, injected starter inventory or hidden RaidAuthority is used by the
normal New/Continue flow. Starter creation is the production response to real
New Local Game input.

| Mode | New profile process | Independent Continue process | Total |
| --- | --- | --- | --- |
| Headless | 73 checks / 0 failures | 63 / 0 | 136 / 0 |
| Graphical | 79 checks / 0 failures | 69 / 0 | 148 / 0 |

These are 284 check executions across four processes, not 284 distinct scenarios.
The graphical runs additionally verify the native window, viewport and raw readback
are exactly 1920x1080 before product mount and before each screenshot write.
Ten native PNGs cover Title, menu, bunker, inventory and settings in both processes.
Every image is 1920x1080; no image-model output, resizing or fixture-only screenshot
substitutes for the actual application view.

The artifact was downloaded, its ZIP hash verified, and the images inspected.
The final menu has the corrected PRE-RAID MVP label, one local-profile action,
shorter local-save status and no stale multiplayer patch-news claim. The bunker
shows the saved local revision; inventory shows the carried ammo and equipped AKM.
Native source-art and existing scene geometry were not replaced.

The logs contain no SCRIPT ERROR/ERROR/parse failures. Each graphical process
emits `WARNING: Virtual Machine detected, switching to ANGLE.` These two notices
are retained: this is not a zero-warning claim or a physical-controller playtest.

All four processes report this accepted profile fingerprint:

```text
3867c9aaa503309b121f7edb374c580e9a18b3e48e38e02947f498d38a64599f
```

Matching fingerprints establish persisted state, not pixel repeatability between
New Game and Continue. Those captures intentionally show different save/menu states.
Individual PNG hashes are recorded in `capture_manifest.json`.

## Exercised normal flow

1. Default F5 application scene -> Title -> actual Enter -> usable offline menu.
2. Actual New/Continue button -> authored bunker, with no Steam/account requirement.
3. Inventory key -> existing Character workspace with a real native stash projection.
4. CTRL-click ammo to pockets; select/equip, unequip and re-equip AKM through the
   retained widgets. Accepted changes advance the native revision and local save.
5. Inventory key returns to bunker; Escape opens Pause; Settings changes master
   volume. The saved value, visible label and AudioServer bus volume agree.
6. Existing Controls screen opens; Escape returns to the retained Pause caller,
   then the bunker. No developer fixture provider appears anywhere in the path.
7. Confirm close to menu -> Continue -> a fresh inventory binding in the same process.
8. First process exits; second process opens the same actual test save and verifies
   moved ammo, equipped weapon, three remaining stash items, no starter reseeding,
   volume and exact payload digest. No raid, escrow or settlement keys are created.

The runner modifies only the temporary project's user-data namespace to avoid
all real user saves. Production startup/scripts and native add-ons remain the
same. The actual Quit-to-desktop button and physical controller navigation are
not independently driven by these tests; process shutdown/restart and confirmed
close-to-menu are exercised explicitly.

## Failure/recovery coverage

A separate trusted test session uses the real native InventoryAuthority and
explicit fake ProfileFileOperations. It tests failed temp write, unchanged prior
native/disk state, successful retry, rejection of stale duplicate gestures,
New-over-existing rejection, expired controller generations, future inner schema,
and corruption of both profile slots without replacing or reseeding those bytes.

The normal create/Continue path uses actual files. Failure injection is not a
simulated power cut or proof of directory-fsync/interprocess locking. Ambiguous
committed save outcomes remain blocked until reload, not reported as rollback.

The inherited native inventory owns geometry, stack, quantity, container and slot
rules. The new normal-input test covers quick transfer and equipment actions;
it does not claim exhaustive new graphical coverage of all drag/split/merge cases.

## Regressions and CI status at the verified source revision

- Offline bunker integration: success (`35038486063`).
- Exact-output policy and unit suite: pass inside the native job.
- Combat contracts: success (`35038486021`).
- Raid progression contracts: success (`35038486076`).
- Art components: success (`35038486039`).
- Compact map studies: success (`35038486093`).
- Full Northline: success (`35038486098`).
- Freight polish: success (`35038486011`).
- Multiplayer prerequisite inventory: success (`35038486014`), which is inventory
  validation only, not multiplayer go-live or a platform release approval.
- The older standalone bunker-capture workflow is skipped by its named-branch
  restriction (`35038486004`). This MVP's new full-application graphical run does
  capture the actual bunker in both create/Continue processes.

The branch was synchronized with main's newly merged audit tooling. This removed
the prior missing-source failure in the unrelated multiplayer inventory job.
No checker was weakened to obtain a passing MVP result. The final offline workflow
has contents-read permission only, does not retain Git credentials, and has no
source-patching, auto-commit, push or force-update step. Temporary patch transport
files are absent from the final tree.

## Scope and remaining acceptance

This is one offline, local-only bunker profile. F5 uses
`game/bootstrap/offline_application.tscn`; F6 on `ui/main.tscn` remains the old
injection-only shell. Deployment, crafting/upgrades, economy, advanced character
health/progression, online social, Steam sessions and cloud saves remain disabled.
No official server is required. No physical network-disconnection or packet-capture
test is claimed; the new startup path does not initialize those services.

The native pre-raid domain `zerkov.inventory.bunker` combines stash and equipment;
it is explicitly not yet the raid's two-domain loadout/stash conversion. Local
records are not trusted multiplayer authority. A later approved integration must
supply conversion and network ownership rather than silently importing them.

Human visual acceptance, physical-controller playtest and Windows/Linux combined
export acceptance remain open. No full raid acceptance checkbox is changed.
See `game/offline/README.md` for local data, startup and controls. PR #17 remains
unmerged until user review; no production release claim is made.
