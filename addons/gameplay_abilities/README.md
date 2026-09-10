# GameplayAbilities Addon

GameplayAbilities is a deterministic, multiplayer-authoritative gameplay
ability runtime for Godot 4.7. The native GDExtension owns per-entity ability
grants and executions, tags, attributes, effects, tasks, targeting state, and
replication. Your game continues to own input, AI, physics, presentation,
entity spawning, and the `MultiplayerPeer`.

The native extension is required; there is no GDScript gameplay fallback.

## Install

Copy this complete `gameplay_abilities/` directory to
`res://addons/gameplay_abilities/`, including its matching `bin/` files. Then
enable **GameplayAbilities** under **Project > Project Settings > Plugins**.
Available native artifacts and their verification status are listed in
[`release_manifest.json`](release_manifest.json).

## Start here

- [How GameplayAbilities works](docs/how-it-works.md) explains the runtime
  mental model, follows an ability from authored definitions through atomic
  commit, and includes a runnable minimal example.
- [Documentation index](docs/README.md) provides focused paths for authoring,
  ordinary input or AI, multiplayer, tasks, targeting, hooks, reactions, and
  troubleshooting.
- [Authoring guide](docs/authoring.md) covers catalogs and every definition
  resource. [Integration guide](docs/integration.md) shows how game-owned
  controllers and network sessions call the addon.

## Runtime flow in one minute

1. Author one `GameplayDefinitionCatalog` containing the tags, attributes,
   effects, abilities, cues, target schemas, and reactions your game mode uses.
2. Create one `GameplayAbilityComponent` for each gameplay entity. Before
   `configure()`, assign its role, stable entity ID, tick rate, and catalog.
3. Check configuration with `GameplayDefinitionValidator.is_ok(findings)`,
   initialize that entity's attributes, and grant its starting abilities.
4. Send logical activation requests from game-owned input, AI, replay, or
   tests. Give each request an explicit gameplay tick and a command sequence
   that increases for that ability grant, then advance components from one
   game-owned tick source.
5. Observe committed signals for HUD, animation, VFX, and audio. Use a
   `GameplayAbilityWorldCoordinator` for validated cross-entity effects and a
   `GameplayAbilityNetworkBridge` for a game-owned multiplayer session.

Definitions describe what can exist; each component owns its entity's live
state. An activation is a validated transaction: cost, cooldown, declared
effects, hook commands, and owned tags commit together or roll back together.
In multiplayer, clients submit intent and may predict an eligible self-only
subset, while server authority validates and publishes the confirmed state.
