# Task 9 asset pipeline candidate

This is partial implementation of tasks **9.2 and 9.3** in
`add-zerkov-playable-raid-2026-09-09`. Neither task is accepted by this packet.
It is not implementation or approval of all task 9.* work.

## Scope

`tools/art/asset_pipeline.py` consumes the existing registry, without altering
its schema, aliases, asset bytes, source provenance, license status or task
checkboxes. It adds a standard-library-only import audit and deterministic,
explicit-metadata atlas compiler. No production scene is rebound automatically.
No new package, engine binary, font or source art is supplied.

The audit checks every registered runtime file's SHA-256, and checks texture
sidecars for PNG/SVG assets. It enforces lossless compression, the manifest's
mipmap setting, and no import resizing. SVG input must declare bounded integer
pixel dimensions, and its sidecar must retain scale 1.0 with editor scaling and
editor-theme color conversion disabled. The scanner also rejects forbidden
paths and symlinks throughout `assets/`, including unregistered files and empty
directories. It rejects forbidden paths in registered provenance. External
source roots are never read, downloaded, copied or claimed verified.

Filtering is deliberately not treated as a Godot 3-style PNG import flag.
Pixel entries require nearest/no-mipmaps; explicit linear policies for
backgrounds remain linear. Generated `Sprite2D` resources set `texture_filter`
on the CanvasItem and use a top-left pixel origin. Existing UI/world consumers
are unchanged: auditing import metadata alone does not prove their effective
inherited filtering. That integration remains part of 9.2 acceptance.

PNG IHDR validation and SVG XML/dimension validation are not native image
decoding, rendering or visual acceptance. Non-texture files, including fonts,
receive hash checks only and are named separately in the report. This tool is
not a replacement for the full task 9.1 registry validator or the distribution
license gate. Reports always disclose `native_validation: not_run` and
`distribution_approval: not_evaluated`; existing distribution blockers remain
visible and unchanged.

## Commands

Run from the repository root with Python 3.10 or newer:

```sh
python3 -m unittest discover -s tests/tooling -p 'test_asset_pipeline.py' -v
python3 tools/art/asset_pipeline.py audit

# Read-only compilation plan; the current imported project-owned atlas is SVG.
python3 tools/art/asset_pipeline.py compile --asset world.sawmill.greybox_atlas

# Opt-in, create-only resource output. Never changes the source atlas/TileSet.
python3 tools/art/asset_pipeline.py compile --asset world.sawmill.greybox_atlas --write
```

The fixed output is `game/presentation/generated_art/`. Each selected asset gets
one `AtlasTexture` and one presentation-only `Sprite2D` scene per declared
frame. `index.json` records exact manifest/source identities, regions and
filter presets. These scenes have no script, animation callback, collision,
input, damage or authority behavior. Importing generated files may add Godot
sidecars/UIDs; the compiler intentionally refuses to overwrite a changed output
tree rather than deleting engine-generated or user-authored files implicitly.

Selection accepts only an exact registered ID or alias. It rejects pending
assets and assets lacking explicit PNG/SVG atlas metadata. Cells come only
from `source_size`, `cell_size`, `columns`, `rows` and `frame_count`.
An explicit `frame_order` is honored; when absent, output enumerates the
already-declared grid in row-major order. This is a texture-cell convention,
not animation timing, facing, state selection or semantic tile assignment.
Offsets, variable-size crops and unknown atlas fields fail closed until they
have an approved schema. Frame limits are 4,096 per asset and 8,192 per run.

All audit/preflight work and compilation finish before optional output writes.
An identical rerun is read-only. Different existing output is rejected.
Publication stages a new directory and renames it into place; this is a
single-local-writer tool, not a concurrent or crash-durable transaction.
It never deletes or overwrites an existing output tree.

## Readiness and boundaries

The approved workstream order explicitly permits 9.1-9.3 early in Phase C; it
does not require waiting for every task 7 item. However, completion of the art
workstream is not ready on the reviewed main commit:

| Task | Status of this candidate / remaining gate |
| --- | --- |
| 9.1 | Already accepted; original registry remains authoritative and unchanged. |
| 9.2 | Audit/preset logic and generated-scene filtering are implemented. Full real-checkout/native import and existing-consumer filtering review remain required. |
| 9.3 | Metadata compiler can handle the imported Sawmill SVG atlas. The selected external character/environment sheets remain pending; no source selection, sheet geometry or licenses are invented. |
| 9.4-9.6 | Layered player art, per-state/facing composition approval and held-weapon alignment remain unimplemented. |
| 9.7-9.9 | VFX/audio palette and bounded committed/reversible-event presenters remain unimplemented; real producers and presentation integration need separate verification. |
| 9.10-9.11 | Lighting/readability treatment and labeled native animation/combat/AI/screen evidence remain unimplemented. |

The current registry explicitly marks the player arm sheets and Sawmill prop
sheet as `pending_unimported`, along with other selected sources. The main
branch also retains open combat-input/melee, AI integration, extraction and
HUD/summary work. Their current incomplete status must not be converted into
invented committed-event producers or fabricated capture evidence.

Task 3 files, `project.godot`, shared authority/bootstrap, existing UI, native
add-ons, platform pins, task checkboxes and capability specs are untouched.
No smaller-output UI, compact or responsive suite is introduced or executed.
Synthetic small texture fixtures are source-image unit tests, not UI outputs.

## Acceptance still required

Run the focused CI on a complete checkout, then use the pinned supported native
environment for a clean exact-1920x1080 import and the existing asset registry
contract. Load the generated resources with the real renderer, verify clipping
and nearest/linear sampling, and review the unchanged existing consumers.
Import the selected authorized source sheets with verified bytes and authored
metadata before claiming their slicing complete. Do not tick 9.2/9.3 solely
because synthetic tests or the static CI pass.
