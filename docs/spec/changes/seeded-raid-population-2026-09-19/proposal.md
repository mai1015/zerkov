# Seeded Raid Population

## Why

The first playable currently creates three fixed objective crates with identical
hard-coded contents on every raid. The raid already has a deterministic seed,
but loot placement and contents do not consume it. Larger authored maps therefore
have no per-raid population variation and no stable plan that a future host can
replicate or distribute to peers.

## What changes

- Add a game-owned deterministic `RaidPopulationPlan` generated once during
  authoritative deployment.
- Keep authored map geometry, collision, navigation, objective anchors and exits
  fixed.
- Keep all three Supply Run objective containers guaranteed and searchable.
- Select a bounded subset of authored optional container candidates per raid.
- Generate deterministic contents for objective and optional containers from
  independent location/content RNG streams.
- Persist a closed population descriptor containing generator version, map ID,
  seed, map-identity digest and plan digest with deployment and settlement records.
- Present selected optional containers as non-authoritative visual props and make
  them use the existing authoritative search/open/transfer flow.

## Non-goals

- Procedural terrain or building generation.
- Loose-item world pickup, corpse population, dynamic extraction selection or
  enemy population changes in this increment.
- Mid-raid regeneration or per-frame population work.
- Client-side independent population authority.
