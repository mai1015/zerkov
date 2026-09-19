## ADDED Requirements

### Requirement: Original source-backed held poses
The runtime SHALL bind each supported weapon to its authored visual profile and SHALL suppress ordinary arm layers when a combined weapon/arms source replaces them. Unsupported artwork MUST NOT grant gameplay availability.

#### Scenario: Equipped AKM
The same equipped AKM is rendered using the archive AK-and-arms source; there are no additional dangling arms or handoff inventory icon. Unequip restores the appropriate actual melee or empty-handed state.

### Requirement: Committed animation and effects
The renderer MUST sample melee and FX from committed frame data. It SHALL preserve shot idempotency, generation, death and release boundaries and SHALL NOT change authoritative outcomes.

#### Scenario: Rejected shot
Dry fire, reload rejection and cadence rejection produce no new muzzle or impact effect.

#### Scenario: Confirmed hit
A confirmed shot uses original muzzle frames; confirmed damage can use original blood. Material-specific impacts require an actual blocked consequence and an explicit material binding. Unknown surfaces and clear misses produce no invented surface hit.

### Requirement: Reproducible art provenance
Selected sources MUST match their archive hashes and retain their original PNG bytes. A source manifest SHALL distinguish internal provenance from release clearance.

#### Scenario: Changed source
The verification tool rejects a missing or altered source before accepting native evidence; forbidden asset families remain excluded.
