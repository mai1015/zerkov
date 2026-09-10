# Third-party licenses

The GameplayAbilities addon itself is distributed under the MIT License (see
`LICENSE`). It builds against, and its binaries statically link, the
components below. Their licenses are reproduced or referenced here as
required for redistribution.

## godot-cpp

- Project: <https://github.com/godotengine/godot-cpp>
- Pinned revision: see `native/dependencies.json` (`godot_cpp.commit`) — the
  same vendored `thirdparty/godot-cpp` checkout CommonUI builds against (one
  pinned binding revision shared by both addons, never a second incompatible
  one; see `native/dependencies.json`'s note).
- License: MIT.

godot-cpp is copyright (c) 2017-present Godot Engine contributors and is
licensed under the MIT License. The native artifacts in `bin/` statically
link the godot-cpp bindings; the MIT permission notice therefore applies to
those artifacts as well.

## Godot Engine

The addon requires an official Godot Engine editor and export templates
(compatibility minimum declared in `release_manifest.json`). Godot itself is
not redistributed with this addon; consumers obtain it from
<https://godotengine.org>. Godot Engine is licensed under the MIT License.

## No mandatory third-party gameplay or networking runtime

This addon's proposal explicitly commits to adding **no mandatory
third-party gameplay or networking runtime** — deterministic simulation,
tags, attributes, effects, abilities, prediction/reconciliation, and wire
protocol encoding are all implemented from scratch in `native/core/` and
`native/protocol/`.

This was verified, not assumed: every `#include` across
`native/core/`, `native/protocol/`, `native/godot/`, and `native/resources/`
was audited. Beyond the C++ standard library (`<vector>`, `<string>`,
`<unordered_map>`, `<map>`, `<set>`, `<algorithm>`, `<utility>`, `<cmath>`,
`<type_traits>`, etc. — permitted by the shared implementation contract) and
the godot-cpp binding above (required only in `native/godot/` and
`native/resources/`, which are explicitly allowed to depend on it), no
vendored third-party library appears anywhere in the addon's native sources.
In particular:

- No gameplay-ability-framework dependency (no vendored GAS-alike library).
- No third-party networking/transport library. The addon uses Godot's own
  `MultiplayerAPI` / `MultiplayerPeer` contract (game-owned; see
  `docs/protocol.md` and the platform-support spec's "Game-Owned Network
  Transport" requirement) and never links ENet, Steamworks, or any other
  transport SDK from native code. The reference `ENetMultiplayerPeer` harness
  under `examples/gameplay_abilities/net/` is game-layer GDScript that calls
  Godot's own built-in ENet multiplayer peer class — it is not a vendored
  third-party library, and it is not part of the addon's native runtime.
- No JSON/serialization/compression library: the wire codec
  (`native/protocol/gap_codec.*`) is a from-scratch canonical
  little-endian byte encoder, and the manifest fingerprint
  (`native/core/ga_hash.h`) is a from-scratch FNV-1a 64 implementation.

## Glyph and controller artwork

Not applicable to this addon: GameplayAbilities has no input-binding or
glyph-resolution surface (the platform-support and networking specs
explicitly keep `InputEvent` handling out of scope — see
`docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/`). Any
project-supplied ability icons, VFX, or audio used by a game's own cue
adapters are that project's responsibility and out of scope for this addon.
