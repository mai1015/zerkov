## ADDED Requirements

### Requirement: Explicit UI Composition Ownership
The UI SHALL organize screen scenes and controllers by feature and separate reusable components, theme resources, navigation services, and developer fixtures. Shared visual components MUST communicate through public configuration and semantic signals rather than locating the application root or mutating application state.

#### Scenario: A feature configures a shared component
- **WHEN** a screen supplies data and connects the component's public signals
- **THEN** the component renders its own state and emits semantic intent
- **AND** the screen does not need to edit the component's internal child nodes

#### Scenario: A route resource moves to a feature folder
- **WHEN** the scene and its controller are reorganized
- **THEN** the explicit route catalog resolves the same stable route identifier
- **AND** all preload references and resource UIDs remain valid

### Requirement: Authored Shared Controls and Theme
The project SHALL provide authored shared theme resources and project action controls with documented visual variants. Authored and data-created instances MUST use the same visual and interaction contracts, including the existing pixel-aligned border behavior.

#### Scenario: A button is created by either supported path
- **WHEN** an authored instance or a dynamic factory selects the same button variant
- **THEN** typography, normal, hover, pressed, focus, and disabled states agree
- **AND** a single input produces at most one semantic activation

#### Scenario: Configurable component data changes
- **WHEN** public configuration is set before mounting or updated after mounting
- **THEN** the corresponding visual values are refreshed without caller access to internal children
- **AND** editor-supported properties preview safely without runtime application services

### Requirement: Retained Authored Screen Shells
Screens MUST retain their fixed authored shell during ordinary state updates. Variable item or row populations MAY be rebuilt inside their owning data component, but filtering, selection, and queue updates SHALL NOT replace unrelated fixed controls or substitute a second programmatic screen implementation.

#### Scenario: Inventory filter changes
- **WHEN** the player changes an inventory filter or search value
- **THEN** the owning grid renders the expected item set
- **AND** the inventory shell, search input, navigation, and unrelated action controls remain the same instances
- **AND** applicable focus, caret, and scroll state are preserved

#### Scenario: A crafting queue changes
- **WHEN** a queue entry starts, progresses, or is collected
- **THEN** the owning queue/detail components update
- **AND** the screen header and unaffected controls are retained with no duplicate signals

### Requirement: CommonUI Navigation Ownership
The navigator SHALL use declared route roles and CommonUI operations to manage temporary screen history and layer placement. The HUD MUST remain on the HUD layer beneath temporary menu screens, and committed route state MUST only change after a successful stack operation.

#### Scenario: Pause covers the raid HUD
- **WHEN** pause opens and subsequently closes
- **THEN** the HUD instance remains retained on the HUD layer
- **AND** the pause menu is pushed and popped on the menu layer
- **AND** appropriate lower input is suspended and restored with valid focus

#### Scenario: A workspace tab changes
- **WHEN** the player switches among character or utility workspace tabs
- **THEN** the navigator changes the active workspace screen according to its declared policy
- **AND** Back returns to the retained caller without accumulating a tab-history loop

#### Scenario: Navigation fails or is canceled
- **WHEN** scene resolution, mounting, or activation fails or a request is canceled
- **THEN** the committed route and visible stack remain consistent
- **AND** the navigator reports the result without claiming the requested destination became active

### Requirement: Shared Responsive Composition
Shared chrome and feature content SHALL retain their existing desktop and compact layout APIs for compatibility. Resizing MUST preserve active screen identity, and responsive placement MUST use explicit content references rather than inferred screen coordinates. The current first-playable acceptance path is exact 1920×1080 only; current agents and tests MUST NOT invoke smaller or compact layouts or regenerate their captures until task 11.8 or a later approved display-support proposal reopens them.

#### Scenario: The exact first-playable window reflows
- **WHEN** the exact 1920×1080 first-playable window is resized and its existing layout API is reapplied
- **THEN** existing screen and shared chrome instances remain present
- **AND** selected panes, applicable text/caret, focus, scroll, active drag intent, and pending dialog input remain valid
- **AND** no duplicate nodes or signal connections accumulate

#### Scenario: A first-playable window remains on the desktop path
- **WHEN** its size is the exact 1920×1080 current acceptance target
- **THEN** the 1920×1080 logical composition is proportionally fitted
- **AND** the navigator does not remount the active route

### Requirement: Isolated UI Preview and Input Containment
The project SHALL supply an explicit fixture-backed preview host for routable scenes and shared components. Interactive overlays MUST use CommonUI lifecycle ownership and prevent both routed and raw input from triggering covered actions.

#### Scenario: A screen is previewed independently
- **WHEN** the preview host is configured with a scene and fixture provider
- **THEN** the screen renders and can exercise its declared UI intents without `/root/Main`
- **AND** no production gameplay authority or persistent profile mutation is required

#### Scenario: A modal or screen catalog covers a screen
- **WHEN** the player uses pointer, keyboard, or controller input in the overlay
- **THEN** covered screen actions cannot fire and focus remains within the overlay
- **AND** dismissal resolves once and restores an eligible prior focus target

### Requirement: Visual and Behavioral Migration Evidence
The migration MUST preserve all 28 route identifiers and the established visual contract. Current acceptance SHALL include focused lifetime/component regressions, the existing relevant UI and border suites, and native captures at exact 1920×1080 only. Existing smaller and compact captures remain historical evidence and current agents/tests MUST NOT execute their suites or regenerate them until task 11.8 or a later approved display-support proposal. Runtime errors MUST count as failures even when the engine process returns zero.

#### Scenario: A feature family finishes migration
- **WHEN** its old builders and resource paths are removed
- **THEN** its route and current exact-1920 action/input tests pass
- **AND** native captures confirm the accepted typography, geometry, imagery, and border behavior

#### Scenario: Final UI migration is reviewed
- **WHEN** all families have moved to the proposed ownership model
- **THEN** all 28 route IDs resolve and all applicable suites pass without runtime errors
- **AND** native comparisons cover the exact 1920×1080 first-playable output
- **AND** smaller/compact comparisons remain historical and are not executed or regenerated by current acceptance
