# Tasks

- [x] O1: Offline app root and truthful title/menu, with no Steam/network dependency.
- [x] O2: One real local profile; explicit starter creation, Continue and error/recovery states.
- [x] O3: Durable native stash/loadout and equipment commands in the existing workspace.
- [x] O4: Existing bunker, pause, controls/settings and individually locked future features.
- [x] O5: Native normal-input new/continue, inventory, equipment, navigation and relaunch tests.
- [x] O6: Native 1920x1080 captures and source-policy/regression evidence.

## Implementation evidence

Verified implementation: `83cfcb6a5d24cd72cf6acb8951ee92ae5ad88c55`.
Read-only full-native workflow: https://github.com/mai1015/zerkov/actions/runs/35038486063

Headless create/Continue: 73/0 and 63/0 (136 checks).
Graphical create/Continue: 79/0 and 69/0 (148 checks).
All four processes preserve the same accepted local profile fingerprint.
Ten native 1920x1080 PNGs were downloaded, hash-verified and inspected.
See `docs/qa/offline_bunker/VALIDATION.md` and `capture_manifest.json`.

O3 uses the existing native move/rotate/split/merge/equipment semantics. The
new input-driven end-to-end test specifically exercises quick transfer and
equip/unequip/re-equip; it is not an exhaustive new graphical matrix for every
inherited inventory gesture. Save-failure and stale-generation rejection tests
are explicit native-inventory contracts with a separate fake filesystem.

## Remaining review, not inferred from automation

- [ ] User visual acceptance and physical-controller playtest of this milestone.

Scope was approved by the user's "yes, lets go", offline-default decision and
local-only-save MVP instruction. These checks mark implementation/native evidence,
not human sign-off, Windows/Linux release acceptance or the broader raid task list.
No raid, deployment, crafting, Steam sessions, cloud sync or official server is
enabled. Later deployment needs an explicit conversion of the pre-raid inventory
record; local-save trust must not silently become future multiplayer authority.
