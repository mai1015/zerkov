# Zerkov third-party and distribution notices

This file is the human-readable index for
`config/distribution_licenses.json`. The machine-readable registry is the
release gate; a public build must contain only entries marked `cleared` and
must preserve every referenced license and notice file.

## Add-ons

| Add-on | Version | License status | Notice |
| --- | --- | --- | --- |
| CommonUI | 0.1.2 | MIT, cleared | `addons/common_ui/LICENSE` and `addons/common_ui/THIRD_PARTY_LICENSES.md` |
| Common Vision | 0.1.0 | MIT, cleared | `addons/common_vision/LICENSE` and `addons/common_vision/THIRD_PARTY_LICENSES.md` |
| Gameplay Abilities | 0.2.0 | MIT, cleared | `addons/gameplay_abilities/LICENSE` and `addons/gameplay_abilities/THIRD_PARTY_LICENSES.md` |
| Inventory System | 0.4.0 | **Blocked** | The locked repository contains no license grant or package-level third-party notice. Internal evaluation only. |
| Level Task System | 0.1.0 pre-release | MIT, cleared | `licenses/level_task_system-MIT.txt` and `addons/level_task_system/THIRD_PARTY_LICENSES.md` |
| Weapon System | 0.1.0 | **Blocked** | Its reference notice does not license Weapon System itself. The locked repository contains no license grant. Internal evaluation only. |

All six native extensions build against `godot-cpp` commit
`5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731`. Its MIT text is preserved at
`licenses/godot-cpp-MIT.md`.

## Selected asset families

- Chakra Petch is covered by `assets/fonts/OFL-ChakraPetch.txt`.
- IBM Plex Mono is covered by `assets/fonts/OFL-IBM-Plex-Mono.txt`.
- Art under `assets/handoff/` and `assets/original/` has no provenance record
  in this workspace. It remains suitable for internal prototyping only and is
  blocked from public distribution until the project owner records ownership
  or a redistribution grant.

This inventory is not legal advice. It is a deterministic packaging gate and
does not infer a license where the source package supplies none.
