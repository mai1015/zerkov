# Integrate the remaining authored bunker workspaces

The user approved the unified bunker walkthrough and requested integration of
the other bunker UI. This continues that UI scope without implementing or
claiming construction, recipe execution or online sessions.

Reuse the existing Crafting, Build Mode and Session scene layouts. Provide one
navigation strip on the existing hub, live read-only inventory/campaign data,
clear unavailable-service copy, and the same return-to-bunker flow. Keep the
approved storage/health/planning actions and all offline domain owners intact.
No fork/addon/lock/persistence-format or production feature-gate changes.

The existing controllers call fixture state for ingredients, queue timers,
construction costs, occupants and invite codes. Production binding must bypass
those controllers completely, not run them and hide a few results afterward.
