## ADDED Requirements

### Requirement: Item-backed Weapon Builds

Each customizable firearm SHALL retain one stable Inventory item identity. Every installed part SHALL also remain one real Inventory item instance nested beneath the weapon's provided parts container, and the weapon SHALL carry one canonical bounded build component that maps semantic slot IDs to those installed child item IDs.

#### Scenario: Weapon with installed parts is transferred
- **WHEN** an authoritative inventory transfer moves a weapon that has installed parts
- **THEN** the complete weapon subtree SHALL move with the same weapon and part item identities
- **AND** the canonical build component SHALL still reference only children inside that transferred subtree
- **AND** no duplicate or replacement part identities SHALL be created

#### Scenario: Build component references an external or missing part
- **WHEN** reconciliation sees a slot mapping whose part item is absent or is not a child of the weapon
- **THEN** the build SHALL be rejected as invalid
- **AND** the system SHALL NOT fabricate, reseed, or silently drop the mismatched part

### Requirement: Explicit Bounded Compatibility

Every weapon platform and part definition SHALL use stable authored slot/category, size-class, and compatibility metadata. Runtime compatibility SHALL be determined from sealed definitions rather than source filenames or visual appearance.

#### Scenario: Compatible owned part is previewed
- **WHEN** the user selects an owned part whose category, size class, required tags, and blocked tags satisfy the selected weapon slot
- **THEN** the Gunsmith SHALL expose the candidate as compatible
- **AND** the preview SHALL identify the exact target semantic slot

#### Scenario: Incompatible part is inspected
- **WHEN** the user inspects a part that cannot be installed
- **THEN** the Gunsmith SHALL leave authoritative state unchanged
- **AND** it SHALL expose a concrete incompatibility reason such as category mismatch, size mismatch, missing required tag, blocked tag, or unavailable slot

### Requirement: Atomic Authoritative Build Mutation

Install, remove, swap, and preset-apply operations SHALL be idempotent authoritative commands guarded by expected inventory and build revisions. A requested build mutation SHALL either commit one complete valid post-build across Inventory and Weapon runtime integration or fail without presenting a partial successful build.

#### Scenario: Install succeeds
- **WHEN** a valid command installs an owned compatible part into an empty slot
- **THEN** the part SHALL move into the weapon's parts subtree
- **AND** the canonical build revision SHALL advance exactly once
- **AND** the accepted WeaponAuthority attachment loadout SHALL agree with the committed build
- **AND** the confirmed projection SHALL identify the installed part item and definition

#### Scenario: Swap fails preflight
- **WHEN** a swap command has a stale inventory revision, stale build revision, missing part, incompatible part, invalid destination, or unavailable native loadout
- **THEN** inventory bytes, build bytes, weapon runtime state, and revisions SHALL remain unchanged

#### Scenario: Exact command replay
- **WHEN** the same accepted command identity and payload are submitted again
- **THEN** the terminal result SHALL replay without additional mutation
- **AND** reusing that identity with a different payload SHALL reject

### Requirement: Flat Native Runtime With Expanded Slot Kinds

The native Weapon System SHALL remain bounded to at most eight flat attachment slots per weapon. V1 SHALL add Barrel and Laser slot kinds additively to Optic, Muzzle, Stock, and Grip, while attachment-provided recursive slots remain unsupported.

#### Scenario: New native slot kinds are used
- **WHEN** a reviewed platform declares Barrel or Laser slots
- **THEN** the native catalog, snapshots, deltas, command codec, and compatibility handshake SHALL represent those kinds unambiguously
- **AND** an older incompatible protocol/catalog SHALL reject rather than reinterpret the new values

#### Scenario: Attachment attempts to provide another slot
- **WHEN** a part definition declares a child/provided attachment slot in v1
- **THEN** catalog validation SHALL reject the definition

### Requirement: Gunsmith Preview Is Non-authoritative

The Gunsmith workspace SHALL render immutable confirmed state plus reversible preview state. Selecting a candidate part, changing filters, loading a preset preview, or inspecting stat deltas SHALL NOT directly mutate InventoryAuthority, WeaponBuildAuthority, or WeaponAuthority.

#### Scenario: User previews multiple alternatives
- **WHEN** the user previews several parts and then chooses Revert or leaves the screen
- **THEN** the weapon item, installed part subtree, build component, native attachment loadout, ammunition, and revisions SHALL remain byte-identical to the last confirmed state

#### Scenario: User applies the preview
- **WHEN** the user chooses Apply
- **THEN** the UI SHALL submit one bounded build intent
- **AND** it SHALL update the committed display only after an authoritative success receipt and projection

### Requirement: Gunsmith Workspace

The application SHALL provide an original Zerkov Gunsmith workspace for owned firearms with an assembled weapon preview, semantic slot list/tree, owned/compatible part browser, explicit incompatibility reasons, confirmed-versus-preview stat deltas, Apply/Revert controls, and local preset controls.

#### Scenario: Owned weapon opens Gunsmith
- **WHEN** an owned customizable firearm is opened from Character or its context action
- **THEN** the workspace SHALL display that exact weapon item identity and confirmed build
- **AND** it SHALL NOT substitute a fixture weapon or starter build

#### Scenario: Unsupported source layer is absent
- **WHEN** a family lacks an authored stock, scope, grip, barrel, or other layer
- **THEN** preview composition SHALL preserve the authored absence
- **AND** it SHALL NOT synthesize a fake source layer

### Requirement: Definition-level Presets

Local Gunsmith presets SHALL store platform and part definition IDs only, not inventory item IDs. Applying a preset SHALL resolve actual owned compatible part instances against the current Inventory snapshot and SHALL be all-or-nothing.

#### Scenario: All preset parts are owned
- **WHEN** a preset can be satisfied from compatible owned part instances
- **THEN** resolution SHALL be deterministic
- **AND** Apply SHALL submit one complete authoritative desired build

#### Scenario: Preset has missing parts
- **WHEN** one or more required part definitions are not available as compatible owned items
- **THEN** the workspace SHALL list the missing definitions
- **AND** inventory, build, and weapon runtime state SHALL remain unchanged

### Requirement: Authoritative Stat Projection

Committed Gunsmith stats SHALL be derived from authoritative owners. Weapon attachment modifiers SHALL come from the accepted native WeaponAuthority build, while item/subtree mass SHALL come from InventoryAuthority. Preview calculations SHALL be differentially verified against the same canonical modifier algebra before they are shown as predicted results.

#### Scenario: Build changes recoil and mass
- **WHEN** a committed build installs parts with recoil modifiers and additional item mass
- **THEN** the confirmed recoil display SHALL match WeaponAuthority's accepted effective modifier result
- **AND** the confirmed mass display SHALL match InventoryAuthority's subtree mass
- **AND** the UI SHALL NOT maintain an independent authoritative stat total

### Requirement: Raid Pose-profile Gating

A firearm SHALL be deployable only when its platform has both an authoritative combat definition and an approved held-pose presentation profile. Gunsmith catalog or preview support alone SHALL NOT imply raid support.

#### Scenario: Customizable weapon lacks pose profile
- **WHEN** the user attempts to deploy with a firearm that is cataloged for Gunsmith but lacks an approved raid pose profile
- **THEN** deployment SHALL reject that primary weapon with an explicit presentation-unavailable reason
- **AND** the raid SHALL NOT reuse AKM arms, a fixture gun, or another platform's pose

#### Scenario: Approved customized weapon deploys
- **WHEN** a platform has an approved pose profile and a valid committed build
- **THEN** raid presentation SHALL consume that confirmed build
- **AND** gun-local muzzle effects SHALL use the active build's authored muzzle output anchor
- **AND** authoritative hit/impact positions SHALL remain world-space consequences independent of cosmetic movement

### Requirement: Existing AKM Identity Migration

Existing persisted AKM items SHALL remain the same item identities when the Gunsmith capability is introduced. An AKM with no build component SHALL reconcile to the authored default/empty build without reseeding equipment, refilling ammunition, or replacing the weapon instance.

#### Scenario: Existing save opens after Gunsmith update
- **WHEN** a profile created before the Gunsmith build component is loaded
- **THEN** the original AKM item ID, equip state, loaded-round state, and inventory placement SHALL remain unchanged
- **AND** any newly created default build metadata SHALL be deterministic and shall not create attachment items
