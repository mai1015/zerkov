# Third-party licenses

The CommonUI addon itself is distributed under the MIT License (see `LICENSE`).
It builds against, and its binaries statically link, the components below. Their
licenses are reproduced or referenced here as required for redistribution.

## godot-cpp

- Project: <https://github.com/godotengine/godot-cpp>
- Pinned revision: see `native/dependencies.json` (`godot_cpp.commit`).
- License: MIT.

godot-cpp is copyright (c) 2017-present Godot Engine contributors and is
licensed under the MIT License. The native artifacts in `bin/` statically link
the godot-cpp bindings; the MIT permission notice therefore applies to those
artifacts as well.

## Godot Engine

The addon requires an official Godot Engine editor and export templates
(compatibility minimum declared in `release_manifest.json`). Godot itself is not
redistributed with this addon; consumers obtain it from
<https://godotengine.org>. Godot Engine is licensed under the MIT License.

## Glyph and controller artwork

No controller glyph artwork is bundled with this addon. `InputGlyph` resolves
logical glyph identifiers to project-supplied assets. Console and licensed
controller artwork are the integrating project's responsibility and are out of
scope for this repository (see the packaging notes on unsupported targets).
