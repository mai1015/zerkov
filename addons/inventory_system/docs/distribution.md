# Installation and Distribution

How to add this addon to a project, which artifacts exist for which
platforms, how a target earns the right to be called "supported," and the
checksum/CI workflow that keeps `release_manifest.json` honest.

## Installing the addon

1. Copy (or vendor via your own tooling) the whole `addons/inventory_system/`
   directory into your project.
2. Add it to your project's enabled plugin list
   (`project.godot`'s `[editor_plugins] enabled=PackedStringArray(...)`), e.g.:
   ```
   enabled=PackedStringArray("res://addons/inventory_system/plugin.cfg")
   ```
   Enabling the plugin registers the editor "Validate Inventory Catalog" tool
   ([`authoring.md`](authoring.md)); it does **not** add a process-global
   autoload — see `plugin.cfg`'s own description field.
3. Make sure a platform/build-type native artifact your target needs actually
   exists under `addons/inventory_system/bin/` (see "Building the artifact"
   below) and is declared in `addons/inventory_system/inventory_system.gdextension`.
   Godot refuses to start the project — loudly, not silently — if the
   declared artifact for the current target is missing or fails to load
   (`inventory_system.gdextension`'s own header comment; verified by
   [`verification.md`](verification.md)'s extension-load smoke test).
4. This is a **required native C++ GDExtension**: there is no pure-GDScript
   fallback implementation. A target with no built/validated artifact is not
   usable, full stop — see `docs/README.md`'s opening paragraph.

## Optional adapters

`inventory_common_ui` and `inventory_gameplay_abilities` are separately
distributed addons and are not included in this standalone package. When
installed, each lives beside this addon under `addons/` and includes its own
`plugin.cfg` and `README.md`.
Install and enable them the same way, independently of each other and of
this addon's own plugin toggle. Both depend ONLY on this addon's and their
target sibling's public façade — never the reverse, and never on each
other's internals — so this core addon behaves identically whether zero,
one, or both adapters are present (tasks 9.6/10.8, exercised by
`tests/inventory_system/vertical/inv_vertical_main.gd`'s adapter-matrix
sections). See [`presentation.md`](presentation.md) for what each adapter
adds on top of the base presentation layer.

## Dependency direction

```
inventory_system (core: native/, controls/, runtime/, editor/)
        ^                              ^
        |  (public façade only)        |  (public façade only)
inventory_common_ui           inventory_gameplay_abilities
        |                              |
   depends on CommonUI's         depends on Gameplay
   public façade too             Abilities' public façade too
```

`inventory_system` itself never references CommonUI or Gameplay Abilities.
When the optional adapters are installed, see their package READMEs for each
adapter's one-way dependency statement, and see
`docs/inventory/contracts.md`'s "Reserved packages and namespaces" table for
the reserved namespace/ownership split this direction is built on.

## Building the artifact

```sh
scons platform=macos target=template_debug arch=universal -j8
scons platform=macos target=template_release arch=universal -j8
```

Substitute `platform=`/`arch=` for your target (`linux`/`x86_64`,
`windows`/`x86_64`, `web`/`wasm32`, `android`/`arm64`|`x86_64`,
`ios`/`arm64`). See [`verification.md`](verification.md) for the full native
test/build/verification chain to run after any change, and its "Sanitizers"
section for this addon's sanitizer policy.

## Platform support state

`addons/inventory_system/release_manifest.json` is the single authoritative
source for exactly which `(platform, arch, build)` artifacts exist, their
`sha256`, and their `support_state` (`"planned"` declared intent only,
`"experimental"` built+loads but not yet export-smoke-verified in this
environment, `"validated"` built+loads+export-smoke passed) — **do not infer
platform support from this document**; always check that file directly.

## Checksum and CI workflow

- `tools/inv_checksums.py --update` — recompute `sha256` for every present
  artifact and mark freshly-built `"planned"` targets `"built"`.
- `tools/inv_checksums.py --verify` — fail if a recorded checksum no longer
  matches its file, or a `"built"`/`"validated"` artifact has gone missing.
- `tools/inv_checksums.py --validate PLATFORM` — promote every present,
  checksummed target of `PLATFORM` to `"validated"` (run this only after the
  export smoke test for that platform passes).

This is `tools/checksums.py`'s (CommonUI's own tooling, not modified per the
shared implementation contract) inventory-system counterpart, mirroring
`tools/ga_checksums.py` exactly — same CLI, same manifest schema, same
update/verify/validate semantics, pointed at
`addons/inventory_system/release_manifest.json` instead.

`tools/inv_export_smoke.sh <preset-name> [debug|release]` exports the named
`export_presets.cfg` preset headlessly and confirms the exported package
actually contains `libinventory_system.*` — mirrors `tools/ga_export_smoke.sh`
exactly (same CLI, same Godot resolution, same skip-with-exit-3 convention
when export templates are not installed locally). See task 12.9 / this
addon's CI jobs for how it is invoked per platform.

## CI jobs

`.github/workflows/ci.yml`'s `inv-*` jobs (additive; they do not change any
CommonUI or `ga-*` job) run, per push/PR:

| Job | What it proves |
|---|---|
| `inv-native-tests` | The engine-free native suite, both plain and under `sanitize=address,undefined` (a 2-entry matrix) — this addon's sanitizer policy applies on every push, not just locally. |
| `inv-boundary-and-fixture-checks` | The `native/core`/`native/protocol` include boundary, and the golden `zerkov_v1` fixture check. |
| `inv-desktop` | Linux/macOS/Windows: build debug+release, every headless suite in [`verification.md`](verification.md)'s suite table, export smoke (debug+release), checksum recording and validated-target promotion, artifact upload. |
| `inv-dedicated-server-export` | Linux x86_64: export-smokes the "Linux Dedicated Server" preset, then runs the dedicated-server-operation suite (`tests/inventory_system/server/inv_server_main.tscn`) as its session smoke. |
| `inv-web` | WebAssembly build + export smoke (not promoted to `validated` — no automated cross-origin-isolated browser smoke test exists in this repository, the same caveat the CommonUI `web`/`ga-web` jobs document). |
| `inv-android` / `inv-ios` | Build + checksum only — no Android/iOS export preset is declared in `export_presets.cfg` for any addon in this repository yet, so there is nothing to export-smoke. |

## Pre-1.0 compatibility policy

This addon is pre-1.0 (`api_version` `0.x`). See
[`../../../docs/inventory/compatibility.md`](../../../docs/inventory/compatibility.md)
for the canonical policy (what may change without a major bump, migration
expectations, golden-fixture rules) and [`compatibility.md`](compatibility.md)
for this façade's own version-query surface.
