# Distribution

Installing the addon, what native artifact your platform needs, and the
pre-1.0 platform support matrix.

## Installing

1. Copy (or, in this repository, simply enable) `addons/weapon_system/`.
2. `Project Settings > Plugins > Weapon System`. `plugin.cfg` declares
   `name="Weapon System"`, `version="0.1.0"`, and `script="plugin.gd"`. `plugin.gd`'s
   `_enter_tree()` checks `ClassDB.class_exists(&"WeaponSystemVersion")` and
   `push_error`s an actionable message if the native library did not
   register for the current platform/build-type — there is no GDScript
   fallback to silently degrade to.
3. The two optional adapters (`addons/weapon_system_inventory/`,
   `addons/weapon_system_gameplay_abilities/`) are separate plugins with
   their own `plugin.cfg`s — enable only the ones a given game needs. Neither
   is required by the base addon, and neither depends on the other.

## Building the extension

```sh
scons weapon_core                       # engine-free core+protocol static library only
scons                                    # default target: full GDExtension shared library
scons platform=macos target=template_debug arch=universal -j8
scons platform=macos target=template_release arch=universal -j8
```

The build writes a platform-specific library under
`addons/weapon_system/bin/`, matching the
library paths declared in `addons/weapon_system/weapon_system.gdextension`
(`entry_symbol = "weapon_system_library_init"`,
`compatibility_minimum = "4.7"`, `reloadable = false`).

See [`verification.md`](verification.md) for the complete test/build command
reference, including the engine-free native suite and boundary/fixture
checks.

## Platform support matrix

Per `addons/weapon_system/release_manifest.json`, a target remains planned
until its artifact builds, loads, exports, and passes role-applicable
conformance. Do not infer support from
`weapon_system.gdextension`'s declared library keys alone; that file
declares every *intended* target, not what is actually built.

| Platform | Arch | Build | `support_state` (manifest) | Verified by |
|---|---|---|---|---|
| macOS | universal | debug | built, experimental | `scons weapon_tests run_weapon_tests=yes` (15/15 at manifest capture time — see [`verification.md`](verification.md) for the current count), `weapon_inventory_main.tscn` (76/76 at capture time), `extraction_combat_demo.tscn -- --demo-smoke` |
| macOS | universal | release | built, experimental | Build succeeds; **release loading is not independently verified** — a non-exported editor run always resolves the debug artifact, so this remains unverified until an export-release smoke test exists (matches `inventory_system`'s identical note in its own `docs/verification.md`) |
| Windows | x86_64 | debug/release | planned | Not built |
| Linux | x86_64 | debug/release | planned | Not built |

Dedicated-server exports (Linux x86_64) are part of V1's stated scope
(weapon-platform-support spec, "Supported Godot and Export Matrix") but have
no built artifact yet per the table above — treat as planned, not shipped.

`addons/weapon_system/release_manifest.json`'s counts/dates above reflect the
manifest's own recorded `verified_by` entries as of this writing; re-read
that file directly for the current state rather than trusting this table if
time has passed.

## Protocol metadata

The packaged `release_manifest.json` and the compiled `PROTOCOL_VERSION`
constant in `native/core/wpn_limits.h` both declare protocol version 2.
`WeaponSystemVersion.get_protocol_version()` reports the compiled value. See
[`integration.md`](integration.md#protocol-v2-and-compatibility-fingerprints)
for the fields a real compatibility handshake must compare.

## Dependencies

The only third-party dependency the native build has is the pinned `godot-cpp`
GDExtension SDK binding recorded in `native/dependencies.json`.
`native/core/` and `native/protocol/` have zero
dependency on Godot, godot-cpp, or any sibling addon (`inventory_system`,
`gameplay_abilities`, `common_ui`) — enforced by `scons weapon_boundary_check`
(`native/tests/check_boundaries.py`).
