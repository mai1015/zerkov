# Zerkov game-owned runtime

This namespace is the product layer around the six independent add-ons. No
file here belongs to an add-on package, and add-ons must not import this tree.

| Directory | Ownership |
| --- | --- |
| `bootstrap/` | Composition roots and process/session startup |
| `content/` | Zerkov-owned catalogs and authored resource registries |
| `domain/` | Engine-light value types, contracts, and ports |
| `domain/ports/` | Replaceable ingress, persistence, and domain seams |
| `raid/` | Canonical tick, raid lifecycle, ordering, and journal runtime |
| `profile/` | Versioned game-owned profile serialization and local file persistence |
| `combat/` | Game-owned hit selection, combat content, and cross-domain policy |
| `adapters/` | Explicit translations between Zerkov and public add-on APIs |
| `ai/vision/` | Sealed Common Vision world configuration, tick budget, and ownership |
| `presentation/` | Read-only projections and visual/audio presenters |

The existing `ui/` tree stays in place until its individual screen families
are migrated to immutable projections. Runtime code must not write `ui/main.gd`
prototype state.
