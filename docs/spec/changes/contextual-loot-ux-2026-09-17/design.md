# Stable equipment; contextual counterpart

The Character and carried-loadout columns keep their positions when loot appears or disappears. Do not rearrange a grid during a drag or shift the player's own inventory to fill the empty third column.

| Context | Right-hand presentation |
| --- | --- |
| Home | Existing stash; no phantom loot tab |
| Raid, nothing in reach | No loot panel or no-container error |
| Raid, eligible crate in reach | Small Nearby card; public label, Search/Open action |
| Searching | Resume search action; no item disclosure, no duplicate search |
| Open | Named existing loot grid, clear Close action, contextual transfer hint |
| Open and genuinely empty | Empty state, existing grid remains a valid destination |
| Filter has no match | No matches and clear-filter action; not Empty |
| Stale/inaccessible/disconnected | Existing authority state and disabled operations; never claim empty |

LocalGame publishes a recursively frozen `nearby_loot` value from the already-computed nearest eligible target. UI does not enumerate world inventory, read hidden snapshots, or grant access. Search is an existing next-tick intent and returns to gameplay so the canonical clock advances. Open reuses the current world policy and runtime binding. Root guards phase, Character route, active modal/picker and the current nearest crate at execution. Epoch guards remain in the existing port.

Leaving the Character family closes presentation-only loot. Switching Gear/Health/Stats preserves it. Close and context removal move focus to a visible Character control; hidden search/filter targets must not be in the focus loop. Filter hints update via existing signals rather than frame polling.

This is a focused adaptation, not a clone of Tarkov's artwork, exact current input map, online pause policy or all inventory mechanics. See research.md for inspected sources and limits.
