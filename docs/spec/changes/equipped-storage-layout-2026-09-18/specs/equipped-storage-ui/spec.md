## ADDED Requirements

### Requirement: Equipment-dependent carried capacity
The local game SHALL display and admit new rig/backpack storage only while the
matching supported item occupies its named equipment slot. Unworn roots SHALL
NOT render any grid, including when legacy contents exist.

#### Scenario: No gear equipped
- WHEN the player has no rig or backpack, including after refresh or reflow
- THEN only pockets and supported secure storage provide carried grids
- AND current-epoch requests into absent gear capacity are rejected

### Requirement: Non-destructive V1 recovery
Legacy contents SHALL remain recoverable without exposing an unequipped grid
or new writable capacity. A filled V1 provider SHALL NOT be removed so as to
orphan its contents.

#### Scenario: Recover an old item
- WHEN an unassigned legacy root holds items
- THEN named non-grid recovery actions can move them through normal admission
- AND stale actions or insufficient valid capacity preserve state without success

### Requirement: Whole-section scrolling
Pockets, gear sections and Secure SHALL share one scroll owner, with Secure last.
Character and Quick Use SHALL stay outside it; counterpart loot scrolls separately.

#### Scenario: Scroll equipped storage
- WHEN the player scrolls to Secure at the end of the carried section
- THEN Character and bottom Quick Use stay stationary

### Requirement: Reuse the authored Quick Use row
Character and the raid HUD SHALL reuse the existing authored QuickUseTitle and
QuickSlot5–8 appearance. The implementation SHALL NOT introduce a replacement
action strip or advertise unsupported item assignments as working.

#### Scenario: Enter Character in a raid
- WHEN the player opens and closes Character during a raid
- THEN each active screen shows exactly one bottom-aligned authored Quick Use row
- AND sample items/counts are hidden, unavailable assignments remain disabled,
  and feedback does not cover the row
