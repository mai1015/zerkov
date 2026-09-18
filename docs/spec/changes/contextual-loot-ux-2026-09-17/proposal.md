# Contextual inventory and loot UX

The user requested a Tarkov-informed detail pass, explicitly rejecting an always-visible Loot tab and “No container open” panel. This implements that requested behavior while retaining the approved section header, Character layout and palette.

No active container means no loot tab, search/filter controls or empty loot workspace. A compact Nearby card appears only for the current crate already admitted by the existing world interaction policy. It reveals a public name and searched/searching state, not contents, value or item count. Its Search/Open intent is revalidated by LocalGame. The actual opened container uses the existing grid with a specific source title; a searched empty container is not confused with no container or a filter with no matches. Returning to gameplay closes the presentation context, never the canonical inventory.

No new loot scan, corpse/ground-item discovery service, search timing rule, native addon, equipment-control integration, save field or simulation polling is introduced. The nearby feature initially covers the game’s registered searchable crates, not a universal vicinity inventory.
