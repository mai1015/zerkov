# Gunsmith integration

Implementation of the approved `tarkov-like-gunsmith-2026-09-18` change.
The user explicitly authorized implementation across the supplied weapon families in the follow-up: "yes, lets go ... build the system for all those weapon".

Inventory owns weapon and part item identities. The game-owned build coordinator validates and commits assemblies; WeaponAuthority owns firearm mechanics. UI drafts and presets never create items. Preview coverage does not imply raid pose readiness.

Implementation and exact-head evidence are tracked in the change's tasks and verification documents. This initial integration checkpoint does not claim completion; it enables the existing source-reproduction workflow to retain the exact branch for native local development.
