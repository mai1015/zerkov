# Offline bunker MVP

## Run the actual application

Use the full repository and its locked Godot `4.7.2.stable.official.ed1daf0bf`.
Open `project.godot` and press **F5**. The production entrypoint is
`game/bootstrap/offline_application.tscn`; F6 on `ui/main.tscn` remains the old
injection-only shell, not this normal application path.

The first MVP is **offline by default and local-save only**. It has no login,
HTTP request, official server, Steam initialization or Steam-installation gate.
Future Steam multiplayer is not enabled. Steam Cloud is not implemented.

## Normal user flow

Title -> Enter -> New Local Game (or Continue) -> Bunker.
Click **STASH / LOADOUT**, or use the current default **I**, to open the retained
inventory workspace. CTRL-click transfers between stash and pockets. Select an
item and click a compatible equipment slot to equip it; click an equipped slot
to return the item to stash. Native inventory rules retain geometry/stack/slot
validation. Closing the workspace returns to the bunker.

Escape opens Pause. Settings exposes local master volume and the existing input
binding screen. From Pause, the return-to-menu action asks for confirmation,
closes the profile session, then permits Continue. Quit and launch the application
again to load the same saved items. Health and Stats are unavailable because no
live health/progression actor is active. Unimplemented actions stay disabled.

One profile is supported in this MVP. Reset, additional save slots, automatic
save migration, raids, crafting/upgrades, resource production, economy, online
social and multiplayer are not supplied by this change.

## Local data and safety

Profile ID: `zerkov.profile.offline.default`.
Storage root: `user://zerkov/profile_store/profiles/`.
Godot resolves `user://` to this application's local user-data directory.
ProfileStore derives a filename from the profile identity and maintains a primary
`.profile` and `.profile.backup`; do not treat the envelope as editable JSON.
Use Godot's Open User Data Folder command to locate the directory on your host.

New Local Game creates starter kit version 1 once: AKM, machete, 30 rounds of
7.62 ammo, four bandages and one splint. Existing, corrupt, incompatible or
foreign-domain profiles are never silently replaced or reseeded.

`OfflineBunkerSession` is the sole pre-raid writer. It stages an edit using the
native InventoryAuthority, saves that candidate through ProfileStore CAS, verifies
its readback, and only then publishes accepted item state. Failed writes preserve
previous native/disk state when known not to have committed. Ambiguous committed
state blocks further edits until reload; it is never presented as a safe rollback.
Stale item gestures and retired session generations cannot write newer state.

The pre-raid record combines stash and carried/equipment roots in one native
inventory under `zerkov.inventory.bunker`. This avoids duplicating native inventory
logic or starting a hidden raid. It is explicitly NOT the two-record raid loadout/
stash schema. A later deployment feature requires an approved native conversion;
opening the bunker creates no raid, deployment escrow or settlement history.

Local data is not authoritative for a future network host. Multiplayer identity,
transport, synchronization, trust and cloud saves remain separate work. The inherited
ProfileStore guarantees are unchanged: in-process writer exclusion and verified
same-directory replacement, not interprocess locking or power-loss durability.

## Validation

Run on the supported full-native host, currently verified on macOS arm64:

```sh
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tests/tooling/run_offline_bunker_gate.py --godot "$ZERKOV_GODOT" --output /tmp/offline-check-new
python3 tests/tooling/run_offline_bunker_gate.py --godot "$ZERKOV_GODOT" --output /tmp/offline-visual-new --graphical
```

Each runner uses a temporary project with a fresh test-only user-data namespace.
It starts the same production application scripts and actual native add-ons, sends
Godot keyboard/mouse events, then launches a separate process for Continue.
Graphical captures require a real exact 1920x1080 drawable and the existing physical
capture guard. No smaller display suite or developer fixture flow is substituted.
The fault-injection contract is separate and explicitly uses fake I/O with a real
native inventory; the normal create/Continue flow uses actual local files.

See `docs/qa/offline_bunker/VALIDATION.md` for executed revisions, results and
remaining manual/visual review. No full raid, Steam, Windows/Linux release or
human controller-playtest acceptance is implied by this MVP.
