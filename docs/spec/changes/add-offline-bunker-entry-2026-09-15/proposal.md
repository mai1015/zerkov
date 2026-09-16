# Offline startup and pre-raid bunker integration

## Approval and scope
The user approved the bounded pre-raid milestone in this conversation, then
specified offline by default, optional future Steam multiplayer, and no official
server dependency. Base: bfae2bd69c6ec3f5efd369bd7858fa629f7b9e05.

Normal Play SHALL reach Title, a local profile menu, the existing bunker, and the
existing stash/loadout workspace. Continue SHALL restore committed item state.
No login, HTTP request, Steam initialization or dedicated server is required.
Steam multiplayer is a future optional composition, not an offline startup gate.

One local profile is supported initially. A versioned starter kit is applied
only by explicit New Local Game when both profile copies are missing. Existing,
corrupt, incompatible or escrowed profiles must never be silently overwritten.
No deployment, RaidAuthority, combat, GAS actor, settlement, crafting, upgrades,
economy or multiplayer is activated by entering the bunker.

The original UI geometry/CommonUI navigation remains. Change only its bindings
and truthful status text; reuse the authored bunker scene and inventory widgets.
Input controls/settings that already work stay accessible; unsupported gameplay
settings are labeled and disabled, not stored as fake functionality.

## Persistence boundary
A pre-raid native inventory profile contains stash and carried/equipment root
containers under ONE native InventoryAuthority. This avoids cross-authority item
copies. Its opaque native record uses a new explicit domain key in the existing
ProfileStore envelope; the standard raid catalog is unchanged. Moving to the
raid's split stash/loadout domains requires an explicit later native migration;
Deploy stays disabled until that conversion and raid composition are accepted.
Offline profiles are local/untrusted by any future network host; they are not
silently promoted to server-authoritative progression.
