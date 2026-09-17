# Native Northline freight authoring

## Why
The user rejected the reduced-resolution, palette-quantized crop-and-draw map
pipeline and explicitly approved native Godot TileMapLayer authoring ("yes, lets
do it"). This change implements that approved direction for one freight slice,
not all nine districts or the live raid.

## Scope
- Retain original full PNG sheets without resampling, quantization or repacking.
- Save terrain and wall faces as native TileMapLayers using external shared
  TileSets. Save placed irregular props as reusable native scene instances.
- Make the saved scene/resources the editable runtime truth: no JSON-driven
  rebuild, source conversion or layout generation during startup.
- Retain the old freight/inspection world coordinates, doors and collision
  footprints. Native 1920x1080 rendering with camera zoom 3 preserves the prior
  640x360 logical-world coverage while displaying original 48px tile detail.
- Validate source hashes, imported pixels, physics, input and edit persistence;
  retain actual Godot screenshots.

## Explicit boundaries
The existing complete Northline review, Sawmill, other map studies, product F5,
local saves, authorities and addon binaries stay unchanged. This is an additive
migration candidate; it does not claim full-map replacement. The native review
is approved to use a 1920x1080 render surface instead of the older 640x360
pixel-world surface. No alternate output sizes are introduced.

Original-sheet installation remains an explicit prerequisite for a repository
checkout. The downloadable standalone project includes the selected sheets.
The PR's source installer copies complete allowlisted PNG bytes from the user's
existing two archives; it does not crop, resize or generate an image. Missing
art blocks native validation instead of substituting placeholders.

## Acceptance
Native runtime/serialization checks and captures must be distinguished from
full graphical editor interaction and full product-host acceptance. Any editor
diagnostics are disclosed, not erased by passing resource serialization checks.
Public distribution/licensing clearance is unchanged.
