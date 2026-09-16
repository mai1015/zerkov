# Offline bunker MVP — execution record

## Verified checkpoint

Production candidate: `6fd5ec534e92ed087ee4c866a60907b9a17db43e`.
Read-only workflow/source-review revision: `fb138e1030642d87137e3e4b880215f3a4db6735`.
Workflow: https://github.com/mai1015/zerkov/actions/runs/35037920737
Artifact: `offline-bunker-native-results`, ID `10423773557`.
ZIP SHA-256: `86be8a8b7323217a70778a10212773c7dbae13d3435b98f9eebe1e537541b9d2`.

Actual macOS full-repository native execution with Godot
`4.7.2.stable.official.ed1daf0bf` passed both headless and graphical flows.
No fixture provider, synthetic inventory seed injected by the driver, forced route
or hidden RaidAuthority was used in the normal flow. Starter creation happens in
production only after actual New Local Game input.

| Mode | New profile process | Independent Continue process | Total |
| --- | --- | --- | --- |
| Headless | 73 checks / 0 failures | 63 / 0 | 136 / 0 |
| Graphical | 79 checks / 0 failures | 69 / 0 | 148 / 0 |

The graphical run verifies the native window, viewport and raw readback are
1920x1080 before product mount and before screenshot writes. Its ten captures
cover Title, main menu, bunker, inventory and settings in both processes. The
ZIP was downloaded, hash-verified and its images inspected, not inferred from logs.
The graphical process logs contain one `Virtual Machine detected, switching to
ANGLE` warning each; there are no script/engine errors. Do not call this zero
warnings or a physical-controller playtest.

All four processes end with this accepted profile fingerprint:
`3867c9aaa503309b121f7edb374c580e9a18b3e48e38e02947f498d38a64599f`.
Matching save fingerprints establish state persistence, not image repeatability;
menu labels intentionally differ between New Game and Continue.

## Exercised path

- Default F5 entrypoint -> Title -> actual Enter -> usable offline menu.
- Actual New/Continue button -> authored bunker with local save status.
- Inventory key -> existing Character inventory controller and native stash.
- CTRL-click ammo to pockets; equip, unequip, re-equip AKM with existing controls.
- Inventory key -> bunker -> Escape pause -> Settings -> master volume -> Controls.
- Escape restores the original Pause caller, then the same bunker.
- Confirm close to menu -> Continue -> fresh inventory binding in the same process.
- Exit the first Godot process; a second process opens the actual same test save.
- Verify item quantities/locations, equipped weapon, no starter reseed, master
  volume and exact accepted payload digest. Assert no raid/escrow/settlement keys.

The separate fault contract uses native inventory plus explicitly fake file
operations to test a failed temp write, unchanged native and disk state, retry,
stale duplicate gestures, New-over-existing rejection, expired controller leases,
future inner schema and corruption of both slots without reseeding or modifying
those bytes. It does not claim real power-loss durability.

The full exact-output policy and its unit suite pass. Maps, freight presentation,
art components and native raid progression workflows also passed at the checkpoint.
The unrelated multiplayer inventory workflow encountered missing source files
because it was introduced on main after this branch's original base; latest main
is being brought into the branch without changing its audited gameplay paths.
That workflow result is not an offline MVP runtime result.

## Final review changes

The checkpoint screenshot revealed stale authored multiplayer patch-note text and
a local-save string overlapping its button. The subsequent source change replaces
those labels, shortens local status text and disables redundant profile management.
It does not alter saved state, scene geometry, command semantics or the starter kit.
A final native rerun is required before treating the new menu pixels as verified.

Full raid/UI integration, Steam sessions, cloud sync, crafting/progression,
additional profile slots, deployed build acceptance and human visual/controller
acceptance remain outside this checkpoint. PR #17 is unmerged.
