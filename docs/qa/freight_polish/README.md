# Freight polish review

Open game/presentation/northline_zone/northline_zone.tscn (F6), select 04 / FREIGHT.
M toggles overview; P enables the collision-aware review walker. G toggles the
freight treatment, H reduces ambient motion, and F3 toggles the inspection ring.
Normal artwork stays at 640x360 world raster / exact 3x / 1920x1080 output.

The before/after captures share the same camera, actor pose and outfit; G changes
only environment polish. They are actual Godot PNGs, not post-processed mockups.
The actor uses a fixed reviewed costume, not inventory or weapon equipment data.

Run the original map/source tests, test_freight_polish.py, and the updated
run_northline_zone_gate.py. The native driver freezes the cosmetic clock and
checks two full processes for identical captures. --motion-frames=144 passed to
the GDScript driver additionally records a six-second 24 fps native frame sequence.
The optional sequence moves the inspector through move_and_collide; it is an
animation demonstration, not production raid gameplay.

ANIMATION_AUDIT.md records existing versus missing animation contracts.
Source and outfit provenance remain explicitly distribution-blocked.
