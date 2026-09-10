# Third-Party References

Weapon System does not vendor or link a third-party weapon runtime.

The following MIT-licensed projects were reviewed as architectural or
presentation references only:

- ChaffGames, `Godot4-FPS-Template`
  (`https://github.com/chafmere/Godot4-FPS-Template`): Resource-based weapon,
  projectile-component, spray-profile, and presentation state-machine ideas.
- ClutteredCode, `Godot-Health-Hitbox-Hurtbox`
  (distributed through the Godot Asset Library as “Health, HitBoxes,
  HurtBoxes and HitScans”): low-level health/hitbox/hitscan component ideas.
- Relintai, `entity_spell_system`
  (`https://github.com/Relintai/entity_spell_system`): authoritative
  game-system and stable-resource-database ideas.

No source, assets, names, or trade dress from those projects are copied into
the addon. Zerkov's project-owned C# combat implementation is used as a
behavioral oracle through repository-owned facts and golden fixtures, not as a
runtime dependency of the addon.
