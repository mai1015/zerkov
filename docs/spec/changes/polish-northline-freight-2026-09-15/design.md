# Boundaries

The freight polish is a child of the environment renderer. Its ground layer is
below existing y-sorted props; all lighting uses the same 640x360 world raster.
The crisp 1920x1080 UI is unchanged apart from review-control hints. Four local
shadowed lamps use mask 2; occluders derive from authored wall/cover rectangles
and do not become gameplay collision or AI visibility. The original zone and
atlas bytes stay unchanged. Decoration never declares loot or story outcomes.

G reverses the visual treatment; H freezes atmospheric motion. Overview and
remote sectors stop cosmetic clock advancement. A 12 Hz sampled visual clock
sets bounded steam/dust commands and atlas-safe vegetation vertex displacement.
No shader TIME, ambient physics bodies, per-frame node creation or random seeds.
Plants are capped at 48, dust at 24, steam at 6. This is an art budget, not a
benchmark. No presentation callback mutates domain state.

The review walker remains a CharacterBody2D inspector, not RaidAuthority's actor.
The pose sampler consumes the distance actually moved after collision. A blocked
actor idles. Gait phase follows distance, idle phase follows presentation elapsed
time, and transitions reset independently. Sprite offsets snap visually, while
collision keeps fractional positions. The review ring is optional F3.

The outfit packs exact source RGBA from eight selected 384x64 PNGs into an eight
row lossless WebP. Each mode has six 64x64 frames with the same 32,48 feet pivot.
Source names/spellings are retained; filenames do not prove clothing colour.

Validation reuses the existing registered native capture driver, which calls a
RefCounted contract module. Freeze effects before captures; compare the same
camera/pose off versus on, and compare two full graphical runs. Motion capture
is a separate explicit optional sequence through the same physical PNG guard.
