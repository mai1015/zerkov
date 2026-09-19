## MODIFIED Requirements

### Requirement: Gun-attached muzzle effect
Muzzle source animation SHALL inherit the currently held firearm transform while its originating committed shot is active. It MUST NOT drag the authoritative impact point with the gun.

#### Scenario: Movement or aim changes during flash
Given a committed shot, when the operator moves or turns before the muzzle animation expires, its emitter remains at the visible barrel while impact geometry is unchanged.

#### Scenario: No visible firearm
When the firearm is removed, hidden by melee/reload, dead or released, muzzle animation SHALL be hidden without manufacturing another shot.

### Requirement: Shared authored melee registration
During the approved Option A attack, knife and arm layers SHALL use the same source-frame index, native scale, canvas pivot and reflection. Canonical equipped identity and hit timing MUST remain unchanged.

#### Scenario: Each attack frame in either direction
For all six source cells, the blade and hand use the same 64x64 coordinate system and (32,48) pivot, without inventory-scale or independent aim-rotation offsets.

#### Scenario: Attack ends or equipment disappears
At recovery completion normal held-weapon art returns; empty/dead/released states cannot retain a blade strip or muzzle effect.
