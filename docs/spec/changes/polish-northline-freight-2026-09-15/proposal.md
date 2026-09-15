# Freight environmental polish and animation audit

The user approved the lighting/depth, purposeful dressing, restrained ambient
motion and animation feedback direction, and asked to polish the map and check
for missing animation setup. This change implements a bounded freight-area pass,
not another map or a gameplay subsystem. Base is PR #8 at
`e9720bbafed702aa372dfea971098fc839c21792`.

Add native task lighting/shadows, reversible non-colliding surface/story details,
wind on existing vegetation, localized steam/dust/water/cable motion, reduced
motion and explicit presentation-time freezing. Fix inspection gait to follow
resolved displacement and separate idle/walk phase. Use a verified fixed outfit
from the supplied sheets, without calling it equipment integration.

Non-goals: AI, weapons, damage, inventory equipment, new cover or collisions,
new authored routes, a merged task-9 animation system, or human visual approval.
