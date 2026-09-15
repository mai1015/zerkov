# Northline Exclusion Zone

The user's follow-up requested a full map rather than a small layout study.
This additive review scene expands Northline from 672x448 to 2688x1792 world
pixels: four times each axis, sixteen times the area, without enlarging sprites.
The original Northline and Mercury studies are unchanged.

Open `northline_zone.tscn` with F6 in the repository. In the standalone package,
open `project.godot` and press F5. Standard Godot 4.7.2 is the tested engine.

## Inspect

- M: full-map overview / return to normal source-pixel camera. Click the map or
  a district button to inspect it. Q/E cycles all nine sectors.
- WASD or left-drag: camera exploration. Shift increases pan speed.
- P: collision-aware walkthrough using the supplied original player artwork.
  WASD walks and Shift increases the inspector speed. This is NOT the raid actor.
  Opening the overview pauses the walkthrough; returning resumes it.
- Tab: three checked route annotations and four proposed exits.

The map starts with a full overview. The outlined rectangle is exactly one
normal 640x360 camera footprint, providing a truthful size comparison.
The overview is intentionally zoomed out (1/6 camera zoom). Detail and walkthrough
return to zoom 1; the world raster stays 640x360 and output stays 1920x1080 at
nearest 3x in both modes. Overview aliasing is not a new gameplay render scale.

## Authored layout

Nine districts: west checkpoint, customs records, north rail sidings, freight
complex, fuel/substation, workers quarters, evacuation clinic, motor pool, and
drainage bypass. Nineteen cutaway interiors, 541 authored prop placements plus
fencing, and 1,814 decals connect through the road spine, rear service route,
rail approach, courtyards and two drainage bridges. This is one continuous map,
not nine separately loaded scenes or repeated copies of the old map.

`zone.json` is the editable source of building rectangles, shared wall solids,
doors, props/footprints, lighting, routes, exits and camera landmarks. Optional
`tools/author_northline_zone.py` regenerates it from the authored layout recipe;
it replaces the JSON, so preserve manual edits first. Run
`python3 tools/review_northline_routes.py --write` after geometry changes to
recompute and validate the review-only route annotations. Do not treat this
solver as an AI navigation owner or ZWorldUnits definition.

Source tiles retain the earlier explicitly recorded 48-to-16 nearest
normalization. The review walker is a lossless composition of eight byte-verified
original character sheets; `review_walker.json` records each source. Rebuild or
verify against the original supplied zerkov.zip with
`python3 tools/import_northline_walker.py --archive /path/to/zerkov.zip`.
No new distribution grant, font, engine binary or image-model output is included.

## Validation and boundary

The Python gate checks all nine districts, nineteen interiors, four entry
points and four proposed exits with six-pixel review clearance. A sealed
cross-map negative control must fail. The native gate moves the actual
five-pixel-radius CharacterBody2D along each exit path and checks collisions,
GUI controls, boundary stops, keyboard movement and twelve exact screenshots.

The inspector never accesses RaidAuthority or domain capabilities. There is no
live combat, AI, loot, extraction trigger, settlement or persistence. This is a
full connected environment and collision walkthrough, not a finished raid.
Full-host regression, production movement/vision adapters, gameplay balancing,
character alignment approval and redistribution provenance remain open.
