# Tarkov-like Gunsmith and Weapon Family Expansion

Status: **Stage 1 proposal — awaiting explicit approval before implementation**

Approval target: **v1 — bounded gunsmith foundation, 32 firearm families, 62 attachment art assets, local presets, authoritative item-backed builds, and staged raid presentation**

## Why

Zerkov currently proves one canonical equipped AKM and melee path, but the supplied `zerkov.zip` contains a much broader weapon set. A fresh archive audit of SHA-256 `ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006` finds:

- **32 firearm families**: 8 AR, 8 SMG, 7 pistol, 5 shotgun, and 4 sniper families.
- **84 family-specific weapon-layer PNGs**, all on matching **96x32** canvases.
- **62 attachment PNGs**, exactly 31 small and 31 large: 10 optics, 10 stocks, 10 grips, 10 barrels, 20 muzzle-device variants, and 2 lasers.
- **5 melee items**, which remain outside the firearm gunsmith except for shared inspection/preset infrastructure.

The native Weapon System already owns authoritative fire/reload state and supports atomic attachment loadout replacement, but its current slot vocabulary and player-facing integration are deliberately minimal. The Inventory System already supports nested item-provided containers, mutable item components, subtree transfer, and deterministic persistence. We should compose those existing authorities instead of building a parallel weapon or inventory simulation.

## What changes

1. Add a game-owned **Weapon Build Authority** that owns semantic firearm builds: stable weapon item identity, stable installed-part item identities, build revision, semantic slot mapping, compatibility validation, and atomic install/remove/swap commands.
2. Represent installed parts as **real inventory item instances nested under the weapon item's provided parts container**. A bounded mutable `weapon_build` component on the weapon item SHALL encode the canonical semantic slot-to-child-item mapping. Moving or looting the weapon therefore moves its installed-part subtree without duplicating identities.
3. Expand firearm content around the 32 source families using stable internal IDs derived from the archive families (AR1…AR8, SMG1…SMG8, P1…P7, SG1…SG5, SN1…SN4) until game-facing names are separately authored. We SHALL NOT infer real-world model names from appearance.
4. Expand attachment content to six player-facing categories: **optic, muzzle, stock, grip, barrel, laser**. Small/large source classification becomes authored compatibility metadata, never filename-only runtime logic.
5. Extend the native Weapon System slot-kind vocabulary additively for **barrel** and **laser** while retaining its bounded flat runtime loadout. The game-owned gunsmith may present slots hierarchically, but v1 SHALL NOT introduce attachment-provided nested slots or rail-on-rail recursive mechanics.
6. Add an original Zerkov **Gunsmith** workspace: weapon preview, slot tree, compatible/owned part browser, clear incompatibility reasons, before/after stat deltas, Apply/Revert, and local named presets. The interaction model may be Tarkov-like; visual design, wording, layout, and assets remain Zerkov's own.
7. Persist presets as **definition-level recipes**, not item-instance IDs. Applying a preset SHALL resolve owned parts at execution time, report missing parts, and mutate nothing if the requested build cannot be completed atomically.
8. Drive the bunker preview from the accepted build immediately after authority confirmation. Raid presentation remains **pose-profile gated**: a firearm may be cataloged/customizable before it is allowed to render/equip in raid. A platform without an approved held-pose profile SHALL be explicitly unavailable for deployment rather than borrowing fake AKM arms.

## Native and authority boundaries

- `InventoryAuthority` remains the owner of item existence, quantity, nesting, mass, transfer, and persistence bytes.
- `WeaponBuildAuthority` owns build semantics and compatibility. It may request inventory mutations and native attachment mutation through game-owned adapters but SHALL NOT mutate either authority's internal state directly.
- `WeaponAuthority` remains the owner of firearm runtime state, attachment modifier folding, reload cadence, recoil, and firing consequences.
- `RaidAuthority` remains the canonical raid tick/order/audit owner.
- UI submits intent and renders immutable snapshots/projections only.

## Non-goals for v1

- No copy of Escape from Tarkov UI, terminology, assets, weapon names, traders, flea market, or economy.
- No recursive adapter/rail tree where one attachment creates new child slots.
- No automatic compatibility guessed from image filenames at runtime.
- No new ballistic simulation, damage model, durability/jam system, repair system, ammunition caliber overhaul, or trader purchasing flow.
- No silent enablement of all 32 firearms in raid before their combat definition and held-pose profile are reviewed.
- No multiplayer launch claim; any protocol change still requires existing compatibility/versioning tests.
- No performance work unrelated to gunsmith/content.

## Acceptance summary

The change is complete only when an actual owned weapon can be opened in Gunsmith, parts can be installed/removed through authoritative commands, the exact part identities survive relaunch and weapon transfer, native weapon modifiers agree with the accepted build, presets fail atomically when parts are missing, bunker preview updates from confirmed state, and deployment rejects any platform lacking an approved raid pose instead of rendering substitute gear.

This proposal intentionally separates **catalog breadth** from **raid-art readiness** so the large archive can become useful without repeating the earlier fake-weapon/incorrect-hand-pose problem.
