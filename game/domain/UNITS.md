# Canonical units

This contract is fixed before level, weapon, vision, or navigation content is
authored:

- one source tile = 32 source pixels;
- one canonical world unit = one 32 px tile;
- one canonical/Common Vision coordinate unit = 1,000,000 microunits;
- one Weapon System world unit = 1,000 milliunits;
- authoritative time = integer ticks at 60 Hz;
- Gameplay Abilities scalar values = 1,000,000 micro-units per whole value;
- Weapon System damage = 1,000 milliunits per whole damage value;
- mass is stored in integer milligrams (Inventory System's canonical unit);
- inventory quantity is stored in the owning add-on's integer item units.

All Godot, tile, Common Vision, Gameplay Abilities, and Weapon System spatial
or damage conversion must go through `ZWorldUnits`. Conversion uses
round-half-away-from-zero (with a narrow single-precision half-tie
normalization) and rejects non-finite or out-of-bounds positions.
Presentation may interpolate pixels, but interpolated values are never written
back into canonical state.
