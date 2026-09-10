# Authoring Resources

Godot Resources are mutable editor input. Configuration validates and copies
them into sealed core definitions; later Resource mutation cannot affect live
authority.

This directory holds the editor-visible authoring counterparts of every
current core definition kind in `native/core/wpn_definitions.h`:

- `HitscanShotProfileResource` (`wpn::HitscanShotProfile`)
- `RecoilProfileResource` (`wpn::RecoilProfile`)
- `AttachmentDefinitionResource` (`wpn::AttachmentDefinition`)
- `AmmunitionBallisticProfileResource` (`wpn::AmmunitionBallisticProfile`)
- `WeaponAttachmentSlotResource` -- one entry in
  `WeaponDefinitionResource.attachment_slots` (`wpn::WeaponAttachmentSlot`)
- `WeaponDefinitionResource` (`wpn::WeaponDefinition`)

`WeaponDefinitionCatalog` (`native/godot/weapon_definition_catalog.h`)
validates and copies their current field values into a sealed native
`wpn::WeaponCatalog` via one `register_*()` method per kind
(`register_shot_profile()`, `register_recoil_profile()`,
`register_attachment()`, `register_ballistic_profile()`,
`register_weapon()`); a live Resource is never canonical authority state, and
mutating one after sealing never changes the sealed catalog's fingerprint
(see `tests/weapon_system/integration/test_definition_catalog.gd`'s
mutation-isolation checks). Adding a future definition kind only means
adding a new Resource here plus a matching `register_*()` method, not
restructuring the ones above.
