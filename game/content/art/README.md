# Explicit first-pass art recipe

`slice_recipe.json` is authoring metadata for the task-9 compiler, not a second
canonical asset registry. Generated registry changes are candidates to merge
into `game/content/asset_registry.json` using the compiler's `--registry` option.

The 20 checked-in PNGs under `assets/original/Main character/Animations/` are
byte-for-byte selected sources supplied by the user for this PR. Origin archive:
`zerkov.zip`, SHA-256
`ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006`.
Each exact archive member, source digest, frame geometry and clip layer order is
recorded in `slice_recipe.json`. All were verified against the supplied bytes.
No forbidden source directory or font binary was imported.

Existing `config/distribution_licenses.json` restrictions still apply. The user
supplied sources for development; this is not a new redistribution grant or
project-owned provenance clearance. Do not change blocked license fields.

The isolated native runner compiles these real sources and validates their
textures and every authored frame/facing sample. Other selected environment,
weapon and item sources can be reproduced using the supplied ZIP. The complete
28-source overlay remains separate until its integrated review.

Base composition is legs -> torso -> arms -> head. Idle, walk, knife attack and
grenade use six 64x64 cells; death uses nine 49x33 cells, not the common grid.
Source-facing plus horizontal mirror is supported. Neither eight directional
artwork nor held-AKM/machete alignment has been approved. No genuine hit-reaction
clip was selected; the source named `bate hit` shows an axe swing and is not
silently used as an injury reaction. Grenade animation does not add gameplay.

No production raid or existing UI is automatically mounted or replaced by this
module. A root-owned projection adapter must drive the animation state and
presenter from committed events and handle generation replacement/release.
