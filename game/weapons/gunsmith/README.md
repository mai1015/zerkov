# Gunsmith integration

Implementation of the user-approved `tarkov-like-gunsmith-2026-09-18` change.
The user explicitly authorized implementation across the supplied weapon families and then requested continuation.

Inventory owns weapon and part item identities. The game-owned build coordinator validates and commits assemblies; WeaponAuthority owns firearm mechanics. UI drafts and presets never create items. Preview coverage does not imply raid pose readiness.

## Recovery checkpoint

This branch incorporates main `2154994e97b93e6d12510f660878b4355558117d` without changing its existing gameplay, map or addon content. The prior branch contained the proposal and this README only. Earlier conversation-only implementation/test reports are not reproducible from that source and must not be used as acceptance evidence for this revision.

Implementation and fresh exact-source evidence will be recorded in the change's tasks and verification documents. This source-reproduction checkpoint does not claim a working Gunsmith or completed tasks.
