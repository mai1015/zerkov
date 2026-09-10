# Zerkov asset manifest

Imported 2026-09-07 for the native Godot UI MVP. The approved handoff at
`/Volumes/Data/Downloads/handoff` is the visual contract described by
`DESIGN.md` and `UI_CONTRACT.md`.

## Import manifest

Each row preserves the source path relative to the source root. For example,
`/Volumes/Data/Assets/zerkov/Ammo/Standard 9mm.png` is available at
`res://assets/original/Ammo/Standard 9mm.png`.

| Source root | Destination root | Files | Scope |
| --- | --- | ---: | --- |
| `/Volumes/Data/Downloads/handoff/assets/` | `assets/handoff/` | 49 | Every file in the approved handoff asset folder, copied byte-for-byte. |
| `/Volumes/Data/Assets/zerkov/Ammo/` | `assets/original/Ammo/` | 48 | All ammo item sprites, including low-resolution and larger exports. |
| `/Volumes/Data/Assets/zerkov/Bunker Items/` | `assets/original/Bunker Items/` | 41 | Small adjacent set retained for bunker/crafting recipes. |
| `/Volumes/Data/Assets/zerkov/inventory items/` | `assets/original/inventory items/` | 60 | All original loot/inventory item sprites. |
| `/Volumes/Data/Assets/zerkov/Weapons Inventory/` | `assets/original/Weapons Inventory/` | 151 | All weapon, melee, and attachment inventory sprites. |
| `/Volumes/Data/Assets/zerkov/UI/UI/` (excluding implementation guides) | `assets/original/UI/UI/` | 172 | Production UI sprites for HUD, inventory, menus, maps, bunker, character selection, marketplace/tasks, and backgrounds. |
| Google Fonts `google/fonts` `ofl/chakrapetch/` and `ofl/ibmplexmono/` | `assets/fonts/` | 7 fonts + 2 licenses | Chakra Petch 400/500/600/700 and IBM Plex Mono 400/500/600. |

The destination paths intentionally retain spaces, capitalization, and the
source folder hierarchy so an agent can trace any file back to the original
inventory. Use an explicit `res://assets/original/...` path when loading these
files; the contract's short `asset_name` resolver is intended for
`assets/handoff` names.

## Handoff art dimensions and intended use

| Asset(s) | Dimensions | Useful screens |
| --- | --- | --- |
| `keyart.png` | 1920×1080 | Title and main-menu backdrop. |
| `bg_raid_frame.png` | 660×371 | In-raid HUD, pause, settings, and summary backdrop; scale/cover at the design canvas. |
| `bunker_map.png` | 2360×1540 | Bunker, build mode, and crafting floor plan. |
| `sil_gear.png`, `sil_health.png` | 876×1786 | Gear/health inventory silhouettes; scale into the body panel. |
| `logo_white_pixel.png` | 262×52 | Title/main-menu logo. |
| `merchant.png` | 172×177 | Trader/task card portrait. |
| `gun_ak.png`, `gun_machete.png`, `gun_shotgun.png` | 154×72 | HUD weapon previews and inventory weapon rows. |
| `wpn_pistol.png` | 76×72 | Pistol slot/weapon preview. |
| `item_battery.png`, `item_potion.png` | 70×148 | Tall inventory item sprites. |
| `item_book.png`, `item_chess.png`, `item_fish.png`, `item_parts.png` | 148×72 | Two-cell-wide inventory/loot sprites. |
| Other `item_*.png` | 72×72 | One-cell handoff inventory/loot placeholders. |
| `tab_gear.png`, `tab_health.png`, `tab_stats.png` | 67×65 | Inventory tab controls. |
| `ico_energy.png`, `ico_health.png`, `ico_thirst.png` | 67×74 | Health-tab/general-stat cards. |
| `ico_longgun.png`, `ico_melee.png`, `ico_shortgun.png` | 137×56, 137×56, 68×56 | HUD ammo/weapon type indicators. |
| `st_all.png`, `st_ammo.png`, `st_armor.png`, `st_clothing.png`, `st_food.png`, `st_guns.png`, `st_util.png` | 43×41 or 62×67 | Stash category filters. |
| `crosshair.png` | 165×172 | Crosshair settings preview. |
| `craft_arrow.png` | 181×245 | Bunker crafting recipe flow. |
| `lvl_icon.png` | 43×46 | Level/rank labels. |
| `ph_backpack.png`, `ph_mag.png` | 70×70 | Container and magazine slot placeholders. |
| `player_sprite.png` | 12×20 | Tiny world/HUD player marker. |

The handoff item and weapon sprites are intentionally small pixel placeholders,
as documented in its README. Import them with nearest filtering; use linear
filtering for key art and other large scene/backdrop art.

## Original source art map

| Destination family | Contents and dimensions | Best use |
| --- | --- | --- |
| `assets/original/Ammo/` | 24 `Ammo Bullets-*` files at 32×32 plus 24 named ammo files at 160×160. Variants are standard, hollow point, subsonic, and armor piercing across the supported calibers. | Inventory stash/rig compatibility highlights, loot slots, and recipe inputs. Use the 32 px exports for dense grids and 160 px exports for enlarged detail. |
| `assets/original/inventory items/` | 60 transparent sprites with source dimensions ranging from 9–61 px wide and 10–60 px high. | Original loot and stash content in 74 px inventory cells; center without stretching. |
| `assets/original/Weapons Inventory/` | 151 transparent sprites across `AR1`–`AR8`, `P1`–`P7`, `SG1`–`SG5`, `SMG1`–`SMG8`, `SN1`–`SN4`, `Melee`, and `Attachments`: 89 at 96×32, 10 at 64×32, and 52 at 32×32. | Weapon rows, attachment sockets, compatibility previews, and loadout slots. The 96 px exports are weapon/large-part sprites; the 64/32 px exports are compact attachment art. |
| `assets/original/Bunker Items/` | 41 tiny transparent recipe/upgrade sprites: 21 at 32×32, 11 at 64×32, 6 at 64×64, 2 at 32×64, and 1 at 96×32. | Crafting requirements, bunker upgrades, and station cards. |

Production UI source art is grouped under `assets/original/UI/UI/`:

| Subdirectory | Files | Intended screens |
| --- | ---: | --- |
| `Background UI/` | 14 | Key art layers, full backgrounds, and capsule variants. `background_full.png` and `background_full_no-logo.png` are 1920×1080. |
| `HUD/hud/` | 21 | Crosshairs, ammo indicator pieces, vitals bars, and HUD fade. |
| `Inventory/inventory/` | 78 | Inventory frame, stash filters, containers, tabs, health/stats bars, loot panel, ranks, and context menu. |
| `character-selection/` | 9 | Character selection panel and silhouettes. |
| `main-menu/` | 18 | Character card, menu buttons, friends/squad panels, and deployment action. |
| `map-selection/` | 5 | Map window, selector, ready/back buttons, and separators. |
| `the-bunker/` | 13 | Bunker map/stations and crafting controls. |
| `marketplace/` | 14 | Merchant/search/task panels for the task/marketplace-style screen. |

Useful source dimensions include `HUD/hud/hud_crossair/hud_crosshair_default.png`
(165×172), the sniper crosshair exports (1146×1146),
`Inventory/inventory/inventory_stash/inventory_stash_frame.png` (1205×1832),
`Inventory/inventory/inventory_load-out/inventory_load-out_common-box-04.png`
(184×184), `character-selection/character-selection_silhouette_contractor.png`
(356×724), `map-selection/map-selection_window.png` (3716×2006), and
`the-bunker/the-bunker_map.png` (2360×1540). These are source UI pieces, not
complete screen overlays; compose them with native Controls.

## Fonts and licenses

All font binaries came from the official `google/fonts` GitHub repository under
the `ofl` directories. The matching license texts are shipped alongside them:

| File | Style | Source |
| --- | --- | --- |
| `assets/fonts/ChakraPetch-Regular.ttf` | Chakra Petch 400 | `https://raw.githubusercontent.com/google/fonts/main/ofl/chakrapetch/ChakraPetch-Regular.ttf` |
| `assets/fonts/ChakraPetch-Medium.ttf` | Chakra Petch 500 | `https://raw.githubusercontent.com/google/fonts/main/ofl/chakrapetch/ChakraPetch-Medium.ttf` |
| `assets/fonts/ChakraPetch-SemiBold.ttf` | Chakra Petch 600 | `https://raw.githubusercontent.com/google/fonts/main/ofl/chakrapetch/ChakraPetch-SemiBold.ttf` |
| `assets/fonts/ChakraPetch-Bold.ttf` | Chakra Petch 700 | `https://raw.githubusercontent.com/google/fonts/main/ofl/chakrapetch/ChakraPetch-Bold.ttf` |
| `assets/fonts/IBMPlexMono-Regular.ttf` | IBM Plex Mono 400 | `https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Regular.ttf` |
| `assets/fonts/IBMPlexMono-Medium.ttf` | IBM Plex Mono 500 | `https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Medium.ttf` |
| `assets/fonts/IBMPlexMono-SemiBold.ttf` | IBM Plex Mono 600 | `https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-SemiBold.ttf` |

License files:

- `assets/fonts/OFL-ChakraPetch.txt`
- `assets/fonts/OFL-IBM-Plex-Mono.txt`

## Scope and caveats

- No source folder named `DO NOT USE` was imported. In particular, character
  and clothing/gear sprite sets remain out of the project.
- Large unused environment/location sets, Steam export/editable files
  (`UI/Steam exports`), the `UI/UX` reference board, and implementation-guide
  screenshots/mockups were intentionally excluded. The approved handoff
  screenshots and references remain at the authorized download location and
  were not copied into runtime assets.
- The adjacent `Bunker Items` family is only 41 tiny files and is included to
  keep crafting/bunker recipe cards from falling back to placeholders. It is
  not a world/environment import.
- PNGs were copied without resizing or recompression. Godot should use nearest
  filtering for pixel sprites and UI icons; keep linear filtering for key art,
  background layers, and other large backdrop imagery.
- Godot may generate companion `.import` metadata files beside the binaries
  while the editor is open; those are engine-generated import state, not extra
  source art in this manifest.
- The source art contains filenames with spaces and occasional spelling/case
  quirks. Do not silently normalize them in screen code; use the exact path in
  this manifest or add a deliberate alias in the shared asset resolver.
- Only `assets/` and this manifest under `docs/` were changed for this import;
  no project, scene, script, or build files were edited.
