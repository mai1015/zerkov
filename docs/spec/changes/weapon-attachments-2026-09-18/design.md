# Design

The previous muzzle effect retained shot-time position/orientation for its whole lifetime. A moving/turning character could leave that effect behind. Replace muzzle drawing in the world-impact loop with a Sprite2D child of the held gun. Its position is the source muzzle minus the gun grip, and its image offset is the source flash origin. The child inherits translation, rotation, scale and reflection. The newest valid committed shot controls its source frame. Hide it during melee, reload, missing gear, death and release; no new shot is invented by moving it. World-impact events and endpoints remain immutable.

Option A uses the whole original 384x64 knife strip, with six 64x64 AtlasTexture frames. It shares the attack body's (32,48) pivot, frame index and left/right reflection, at native scale and zero independent aim rotation. It does not inherit the inventory blade's 0.25 scale, hand offsets or swing angles. The arm remains its original attack sheet. Idle continues to display the equipped machete; only the attack silhouette is the selected knife art.

Registration tests compare all six frame origins, scales and source regions with the actual body/arm layers in both directions. Actual-input gameplay captures exercise both swings and moving/turning muzzle attachment. Dead/stale/duplicate/unequipped states retain their fail-closed behavior.
