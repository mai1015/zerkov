#ifndef INVENTORY_SYSTEM_EXAMPLES_PROFILES_H
#define INVENTORY_SYSTEM_EXAMPLES_PROFILES_H

// Reusable example-catalog builder for the four reference inventory profile
// compositions described in
// docs/spec/changes/add-modular-authoritative-inventory-system-2026-07-26/
// design.md ("Composable inventory model" / "Reference vertical slice") and
// evidenced by tests/inv_test_example_profiles.cpp
// (`examples/profile_matrix`, requirement IA-02, reference flow RF-01).
//
// Every definition below is assembled with ONLY public DefinitionCatalog
// composition -- container layouts, constraints, item traits, and profile
// root containers -- and reuses the builtin feature modules and trait
// schemas from core/inv_builtin_features.h. No new feature module is
// introduced. The goal is to prove that materially different inventory
// shapes (equipment + spatial extraction character, a single large spatial
// stash, an access/filter-restricted world crate, and a non-spatial ordered
// list) all compose from the same core.

#include "core/inv_catalog.h"
#include "core/inv_status.h"

#include <string>

namespace invexamples {

// ---------------------------------------------------------------------------
// Stable identifiers. Exposed so tests and other example content can refer
// to these definitions without duplicating string literals.
// ---------------------------------------------------------------------------

// Profiles.
constexpr const char *PROFILE_EXTRACTION_CHARACTER = "game.profile.extraction_character";
constexpr const char *PROFILE_STASH = "game.profile.stash";
constexpr const char *PROFILE_WORLD_CRATE = "game.profile.world_crate";
constexpr const char *PROFILE_SIMPLE_LIST = "game.profile.simple_list";

// Containers.
constexpr const char *CONTAINER_EQUIPMENT = "game.container.equipment";
constexpr const char *CONTAINER_POCKETS = "game.container.pockets";
constexpr const char *CONTAINER_RIG_GRID = "game.container.rig_grid";
constexpr const char *CONTAINER_BACKPACK_GRID = "game.container.backpack_grid";
constexpr const char *CONTAINER_SECURE_GRID = "game.container.secure_grid";
constexpr const char *CONTAINER_STASH_GRID = "game.container.stash_grid";
constexpr const char *CONTAINER_WORLD_CRATE_GRID = "game.container.world_crate_grid";
constexpr const char *CONTAINER_SIMPLE_LIST = "game.container.simple_list";

// Equipment slots on CONTAINER_EQUIPMENT.
constexpr const char *SLOT_HEADWEAR = "game.slot.headwear";
constexpr const char *SLOT_ARMOR = "game.slot.armor";
constexpr const char *SLOT_WEAPON_PRIMARY = "game.slot.weapon_primary";
constexpr const char *SLOT_WEAPON_SECONDARY = "game.slot.weapon_secondary";
constexpr const char *SLOT_RIG = "game.slot.rig";
constexpr const char *SLOT_BACKPACK = "game.slot.backpack";
constexpr const char *SLOT_SECURE_CONTAINER = "game.slot.secure_container";

// Items shared across every example profile.
constexpr const char *ITEM_HELMET = "game.item.helmet";
constexpr const char *ITEM_BODY_ARMOR = "game.item.body_armor";
constexpr const char *ITEM_RIFLE = "game.item.rifle";
constexpr const char *ITEM_PISTOL = "game.item.pistol";
constexpr const char *ITEM_RIG = "game.item.rig";
constexpr const char *ITEM_BACKPACK = "game.item.backpack";
constexpr const char *ITEM_SECURE_CONTAINER = "game.item.secure_container";
constexpr const char *ITEM_AMMO_9MM = "game.item.ammo_9mm";
constexpr const char *ITEM_RATION = "game.item.ration";
constexpr const char *ITEM_VALUABLE_GEM = "game.item.valuable_gem";
constexpr const char *ITEM_QUEST_KEY = "game.item.quest_key";

// Custom game-authored trait schemas. These compose alongside the builtin
// traits declared in core/inv_builtin_features.h (inv::TRAIT_EQUIPMENT,
// inv::TRAIT_AMMUNITION, ...); no new feature module is introduced.
constexpr const char *TRAIT_HEADWEAR = "game.trait.headwear";
constexpr const char *TRAIT_BODY_ARMOR = "game.trait.body_armor";
constexpr const char *TRAIT_WEAPON_PRIMARY = "game.trait.weapon_primary";
constexpr const char *TRAIT_WEAPON_SECONDARY = "game.trait.weapon_secondary";
constexpr const char *TRAIT_RIG = "game.trait.rig";
constexpr const char *TRAIT_BACKPACK = "game.trait.backpack";
constexpr const char *TRAIT_SECURE_CONTAINER = "game.trait.secure_container";
constexpr const char *TRAIT_LOOTABLE = "game.trait.lootable";
constexpr const char *TRAIT_QUEST_BOUND = "game.trait.quest_bound";

// ---------------------------------------------------------------------------
// Builders. Each function registers into the caller-supplied catalog and
// never seals it -- callers control when, and whether, to seal, matching
// inv::DefinitionCatalog's own registration contract. Registration order
// across these functions does not matter; only the complete set registered
// before inv::DefinitionCatalog::seal() matters.
// ---------------------------------------------------------------------------

// Registers the nine game.trait.* schemas used to filter equipment slots and
// the world-crate loot policy.
inv::Status register_example_trait_schemas(inv::DefinitionCatalog &r_catalog, bool p_reverse_order = false);

// Registers the shared game.item.* catalog: a weapon, armor, a rig and a
// backpack that each provide a nested container, a secure-container item,
// stackable ammo and a consumable, and a valuable/quest-bound pair used to
// demonstrate required/blocked filters.
inv::Status register_example_items(inv::DefinitionCatalog &r_catalog, bool p_reverse_order = false);

// Registers `game.profile.extraction_character`: named equipment slots
// (headwear, armor, primary/secondary weapon, rig, backpack, secure
// container) plus a spatial pocket grid as root containers. The rig,
// backpack, and secure-container items each provide their own nested
// spatial grid, reachable only once the matching item is equipped.
inv::Status register_extraction_character_profile(inv::DefinitionCatalog &r_catalog, bool p_reverse_order = false);

// Registers `game.profile.stash`: one large spatial grid with stacking and
// nesting enabled and no mass capacity.
inv::Status register_stash_profile(inv::DefinitionCatalog &r_catalog);

// Registers `game.profile.world_crate`: a spatial grid whose access policy
// blocks INSERT (items may be looted out but not dumped back in) and whose
// filter policy requires a lootable trait and blocks quest-bound items.
inv::Status register_world_crate_profile(inv::DefinitionCatalog &r_catalog);

// Registers `game.profile.simple_list`: one ordered-list container with
// stacking and count capacity and no spatial, equipment, or mass features,
// proving the core is not coupled to spatial extraction inventories.
inv::Status register_simple_list_profile(inv::DefinitionCatalog &r_catalog);

// Registers builtin definitions plus every example trait/item/container/
// profile above into r_catalog. When p_reverse_order is true, every group
// and every element within a group is registered back-to-front, proving the
// sealed manifest is independent of registration order. When p_seal is
// true, the catalog is sealed before returning.
inv::Status populate_example_catalog(
		inv::DefinitionCatalog &r_catalog,
		bool p_seal = false,
		bool p_reverse_order = false);

} // namespace invexamples

#endif // INVENTORY_SYSTEM_EXAMPLES_PROFILES_H
