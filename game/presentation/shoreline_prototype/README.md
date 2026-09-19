# Shoreline visual prototype

Editable Godot 4.7.2 presentation scene for the generated-v2 coastal art direction.

Open `shoreline_review.tscn` and run the current scene (F6). The world uses varied 64 px terrain, reusable y-sorted props, a cutaway/enterable cabin, contact shadows and shared finite projected shadows.

Controls: WASD move, Shift sprint, F interact, H projected shadows, J contact shadows, R sun direction, F2 overview/follow camera, Tab HUD, C collision debug.

## Production boundary

This scene is deliberately a presentation prototype. It is **not** registered in `NativeRaidMap.PATHS` and does not change raid authority, save data, inventory, AI, extraction, Northline or Blackwater. The production live-map loader currently requires a script-free authored environment and separately owned gameplay geometry. A follow-up integration should migrate the approved visual composition into that contract rather than weakening preflight.
