# Tarkov reference study and Zerkov adaptation

Reference pass: 2026-09-17. This is a UI-structure/detail study, not a claim to have played or exhaustively tested the latest Tarkov client.

## Inspected first-party sources

1. Battlestate Games' published inventory screenshot on the official Steam Left Behind page:
   https://store.steampowered.com/app/4090950/Escape_from_Tarkov__Left_Behind_Expansion_Pack/
   Image: https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4090950/a71c28347602c6455582b0941cadc4c3a7b4b1b8/ss_a71c28347602c6455582b0941cadc4c3a7b4b1b8.1920x1080.jpg?t=1763757995
   Observed: differentiated equipment slots, carried-container groups, a distinct stash counterpart, compact item counts and subordinate Character navigation. This particular screenshot is an out-of-raid stash view, not evidence of every current raid-looting transition.
2. Official developer announcement for Field Guide #1: Basics:
   https://t.me/s/escapefromtarkovEN/4795
   Direct guide: https://www.youtube.com/watch?v=4vkwJAwVrIs
   The announcement explicitly identifies equipment, looting, healing and navigation as its scope. The linked video could not be fully retrieved in this environment; no frame-by-frame or latest-client behavior claim is based on it.
3. Official Patch 1.0.2.5 announcement:
   https://steamcommunity.com/games/3932890/announcements/detail/523118018927001880
   Located as current reference material; the public renderer did not expose the complete article text here. Not used as proof of a specific implemented interaction.

## Design conclusions (our adaptation, not quotations)

| Useful detail | Application to Zerkov |
| --- | --- |
| Stable ownership grouping | Keep Character and carried containers stationary; make only the counterpart contextual. |
| Clear source identity | Open pane names the actual crate instead of the generic Loot category. |
| Progressive disclosure | No item rows, item counts or values before the existing search/open authorization. |
| Compact actionable information | A small Nearby card explains what the player can do now. Do not dedicate an entire screen column to an irrelevant error. |
| Fast inventory operations | Retain existing native Ctrl-click transfer and show its hint only while it is available. |
| Recoverable filtering | Distinguish a genuinely empty open container from a nonempty container hidden by filters. Offer Clear filters only for the latter. |
| Context-sensitive control visibility | No permanent loot tab or inactive search/filter chrome without a source. Hide unavailable swap buttons rather than let their long diagnostic labels overlap the next column; retain truthful equipment placeholders. |

Nearby is a deliberate Zerkov accessibility choice, not a claim that Tarkov has a universal nearby-inventory browser. It identifies only the current crate admitted by the existing range/occlusion policy. No corpse inventory, loose ground items, hidden contents or through-wall list is synthesized.

## Deliberately not copied

No Tarkov artwork, branding, exact layout dimensions, economy, medical simulation or online timing rule is imported. The approved olive-charcoal/brass design and authored Character screen remain. Existing offline menu pause remains: Search returns to gameplay so canonical time advances; opening Character during search offers Resume rather than running a second timer. Equipment-control integration remains a separate workstream.
