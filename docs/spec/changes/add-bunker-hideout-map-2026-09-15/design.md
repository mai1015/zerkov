# Design

The kit's 16px floors, 32px vertical bands, 16px horizontal bands, eight-pixel
wall-plan erosion and 40px projected south faces are explicit. Wall rectangles
are unioned before openings are subtracted. Fixtures fit whole host faces;
upright props sort by authored feet. Floor phase is global and materials do
not rotate. A lossless atlas preserves all 72 source PNG decoded RGBA pixels.

The SubViewport is independent of the crisp interface. A lighting shader
operates only on that world texture. Room selection and emergency lighting
are local presentation state, not simulation. Labels disclose unavailable
services rather than claiming sample resources or progression values.

The existing screen wrapper delegates its inherited build/lifecycle, hides the
legacy visual children and mounts the new view. Other bunker routes and the
original controller are retained. The native test instantiates this exact view
without the unrelated six native add-ons: it is not full-host acceptance.
