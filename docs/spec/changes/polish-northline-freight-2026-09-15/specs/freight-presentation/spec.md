## ADDED Requirements

### Requirement: Bounded reversible environment polish
The freight treatment SHALL remain cosmetic, bounded and reversible without
changing existing map geometry, authored props, routes or domain state.

#### Scenario: Disable and restore
Given an inspected freight sector, toggling G MUST restore the baseline ground
and shadows, and restore the treatment without additional nodes on repeated use.

### Requirement: Reproducible and accessible ambient motion
The treatment MUST support a known presentation time, reduced motion, and
suspension outside its visible sector or in overview mode.

#### Scenario: Frozen capture
Given the same time, camera and actor pose, two graphical processes SHALL output
identical capture bytes on the tested renderer. Invalid sample times MUST leave
presentation state unchanged.

### Requirement: Resolved locomotion presentation
The inspection actor SHALL sample walking from actual post-collision distance,
not requested input, and SHALL preserve fractional physics positions.

#### Scenario: Wall-blocked movement
When a held movement key cannot move the body, the displayed state MUST be idle.

#### Scenario: Start and stop
Transitioning between walking and idle MUST reset the relevant phase rather than
reinterpret a shared elapsed timer at a different frame rate.
