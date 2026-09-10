# Third-party licenses

The Level Task System addon itself is distributed under the MIT License (see
the package-root `LICENSE`). This file records only dependencies that are
actually redistributed or linked; architectural references are not presented
as runtime provenance.

## godot-cpp

The native GDExtension uses the Godot C++ bindings from
<https://github.com/godotengine/godot-cpp.git>, pinned in
`native/dependencies.json` to commit
`5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731` (the 4.7-compatible extension API
sync). That dependency file remains the source of truth for the exact
repository, commit, extension API, and toolchain pin used by a build. The
first standalone package has not yet been promoted and this notice therefore
makes no separate binary-provenance claim.

godot-cpp is licensed under the MIT License and is copyright (c) 2017-present
Godot Engine contributors. Its MIT permission notice applies to artifacts that
statically link the bindings.

## Godot Engine

The addon requires an official Godot editor and compatible export templates;
Godot itself is not redistributed in this package. Godot Engine is licensed
under the MIT License. The minimum engine compatibility and validation target
are recorded in `release_manifest.json`.

## No mandatory gameplay or transport runtime

The core does not vendor a dialogue renderer, quest framework, networking
transport, JSON/serialization library, or reward/inventory runtime. Optional
Gameplay Abilities, Inventory System, Common UI, localization, scene, and
presentation integrations remain host-owned adapters and are not third-party
runtime contents of this package.
