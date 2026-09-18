# Weapon attachment correction

Approved scope: the user requested both attachment fixes, then explicitly selected Option A: original six-frame knife attack art with its matching arm frames. They also asked whether a hand skeleton exists. This is a presentation-only continuation of PR #43 on d66122b.

Use the authored knife strip during committed melee, not the scaled/rotated inventory machete. Keep canonical item identity, balance, input, damage, timing and saves unchanged; the knife silhouette during the machete attack is an explicitly accepted visual substitution. Attach muzzle FX to the live gun, not a frozen shot-time world point. Keep impacts at the authoritative hit point. Do not add an unrelated procedural tracer.

The archive contains image sheets and art-design files, not a skeletal character rig. Current character composition uses Sprite2D layers, not Skeleton2D/Bone2D. Shared frame, pivot and mirror registration are sufficient for Option A. No skeleton or inverse-kinematics migration is proposed.
