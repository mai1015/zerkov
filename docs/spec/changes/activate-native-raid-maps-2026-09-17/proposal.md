# Activate the two native maps for offline raids

User approval: "both look great ... get those ready for live map", followed by
resume/continue. This continues that approved scope on main 82ecaa960d9b2a09033782a78e9069911ecda32f,
not the preparation-only merged PR #30. Original sheets are now committed (#32).

Connect saved Northline and Blackwater scenes to the existing authoritative offline
raid, native inventory/combat/AI/task and local settlement. Select a map through
the existing bunker briefing. Preserve default Sawmill, authored scene editing,
original image detail, immutable UI projections and the current bunker workspaces.
Do not add a server, Steam requirement, new inventory system, or new save backend.

Native runtime tests, source geometry validation, foreign-map/retry regressions,
local-save recovery and actual renderer captures are required before acceptance.
Do not call an inspection walker or a source-only workflow a playable raid.
