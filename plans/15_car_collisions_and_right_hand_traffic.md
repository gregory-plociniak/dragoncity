# Plan: Car Collisions, Occupancy, and Simple Right-Hand Traffic

## Goal

Give cars a minimal sense of physical presence:

1. Cars cannot drive through each other — a car waits if the tile ahead is full.
2. A tile can hold at most **two** cars at once (two-lane capacity, matching the right-hand-lane layout).
3. New cars never spawn onto a tile that is already at capacity.
4. At intersections, apply a **simple right-hand-traffic yield rule** so behaviour looks organic rather than choreographed.
5. Emergent slow-downs and **phantom jams** are acceptable and expected.
6. Cars may get stuck behind a jam; adding roads must eventually unblock them (no permanent deadlock across a session).

This plan is intentionally scoped to movement + arbitration. It does not change sprite geometry, lane offsets, pathfinding, or road graph semantics.

## Current State

- `mygame/app/car_manager.rb`:
  - Each car stores `{ leg: { path, direction }, step_index, progress, speed, ... }`.
  - `advance_car` increments `progress` by `speed` every tick and crosses into the next tile when `progress >= 1.0`.
  - `spawn_new_car` places the car at `path[0]` with `progress: 0.0` unconditionally.
  - `recompute` rebuilds the car list from building pairs. Existing cars survive via `pair_key`.
  - `render` interpolates between `path[step_index]` and `path[step_index + 1]`.
- `mygame/app/road_pathfinder.rb` is A* over the road graph; it has no concept of traffic.
- `mygame/app/road_graph.rb` defines road kinds (`ne`, `nw`, `cross`) and traversable edges.
- There is no occupancy map. Two cars on the same tile overlap silently.

## Problem

- Cars currently clip through each other. With right-hand lane offsets (plan 14) this looks worse, not better, because two cars travelling opposite directions on the same road visually pass through each other at the centerline-adjacent area.
- Spawning uses only "does a path exist?" — cars can appear stacked on top of existing traffic.
- There is no mechanism for a car to wait, so there's no way to produce organic flow or phantom jams.
- When the network is congested or broken, cars have no path-recovery signal beyond `pending_repath` at leg endpoints.

## Design Overview

Introduce three cooperating pieces:

1. **Occupancy map** — authoritative count of cars on each tile. Never exceeds `TILE_CAPACITY = 2`.
2. **Crossing gate** — before a car advances from tile `A` into tile `B`, it must acquire a reservation on `B`. If refused, the car idles on `A` and retries next tick.
3. **Right-hand yield at intersections** — when two cars contend for the same tile in the same tick, a deterministic rule picks which one crosses first; the loser waits.

All arbitration is local (per tile / per contested entry). No global traffic solver. Phantom jams fall out naturally from the local wait-and-retry behaviour.

## Implementation

### 1. Tile capacity constant and occupancy map

Add to `car_manager.rb` near the other tuning constants:

```ruby
TILE_CAPACITY = 2
```

Maintain an occupancy map keyed by tile `[col, row]`:

```ruby
# state.car_occupancy = { [col, row] => count }
```

Rules:

- Initialise `state.car_occupancy = {}` in `GameState.initialize!`.
- Rebuild it deterministically at the start of each `CarManager#tick` from the current `state.cars` list. This keeps the map in sync even after `recompute` adds/removes cars and avoids drift from missed increments/decrements.
- A car occupies exactly one tile at a time — the tile it **currently sits on**. Define "currently sits on" as:
  - `path[step_index]` while `progress < CROSSOVER_THRESHOLD`,
  - `path[step_index + 1]` once `progress >= CROSSOVER_THRESHOLD`.
- `CROSSOVER_THRESHOLD = 0.5` is a reasonable default. The car "hands off" occupancy at the midpoint of the segment. This gives the inbound tile time to free up for the next car while keeping overlap realistic.

Do NOT try to make occupancy continuous (e.g. count a car on both tiles during the crossing). Integer occupancy with a midpoint handoff is enough for two-lane capacity and stays easy to reason about.

### 2. Gate the crossover step

Currently `advance_car` unconditionally increments `progress`. Replace the single increment with a two-phase tick:

1. **Pre-advance check.** If the car is about to reach `progress >= CROSSOVER_THRESHOLD` this tick AND the next tile is at capacity (already has `TILE_CAPACITY` cars that have also crossed), clamp `progress` to just under the threshold (e.g. `CROSSOVER_THRESHOLD - EPSILON`). The car idles at the approach side of the segment.
2. **Advance.** Otherwise apply `progress += speed` as before.

Edge cases:

- The car itself must not be counted against the target tile's capacity when it's the one trying to enter. Compute "capacity available" by excluding the requesting car.
- When `progress` wraps past `1.0` (step completes), `step_index` increments. The tile the car just left drops its count (next tick's rebuild will reflect this).
- A car at the end of its leg (`step_index == path.size - 1`) is stationary on its final tile until `plan_next_leg` gives it a new one. Continue to count it as occupying that tile so other cars respect the queue at building endpoints.

### 3. Right-hand yield at contested entries

In one tick, two cars from different source tiles may both want to cross into the same target tile whose remaining capacity is 1. Resolve that contention deterministically:

- Build a **crossing-intent list** at the start of `tick`: `{ car, from_tile, to_tile }` for every car whose `progress + speed` would reach or exceed `CROSSOVER_THRESHOLD` this tick.
- Group intents by `to_tile`.
- If a group's total requested entries exceed the remaining capacity of `to_tile`, pick winners using the **right-hand yield rule**:
  - Treat each approach direction `delta = to_tile - from_tile` as a compass heading in the isometric projected frame.
  - A car yields to any other contending car whose approach direction is **90° clockwise** from its own (i.e. that car is approaching "from the right" of the yielding car's point of view).
  - If no car in the contention is "to the right" of all others (e.g. head-on from the same axis), fall back to a deterministic tiebreak: smaller `tile_order(from_tile)` wins. Keep the tiebreak deterministic so replays don't diverge.
- Losers are clamped below `CROSSOVER_THRESHOLD` for this tick (same mechanism as the capacity gate). They retry next tick.

Notes:

- Keep the "right" computation in screen/projection space so it matches the visual layout cars render in. `projected_step_vector` in `car_manager.rb` already converts `(delta_col, delta_row)` into screen dx/dy; reuse that. The "right" of a screen vector `(dx, dy)` is `(dy, -dx)` — the same rotation already used by `right_hand_lane_offset`.
- Do NOT model traffic lights, stop signs, or priority roads. One rule, applied everywhere, is the whole point.

### 4. Spawn guard

Update `spawn_new_car`:

- Compute `entry_tile = path[0]`.
- If `state.car_occupancy[entry_tile] >= TILE_CAPACITY`, return `nil` (defer this spawn; it will be retried on the next `recompute`).
- Otherwise proceed as today.

`recompute` already no-ops on `nil` returns. No other changes needed there.

Do NOT try to spawn later along the path to "escape" a full starting tile. That would make spawn position depend on traffic, which is confusing and hides real network problems.

### 5. Stuck-car recovery when the network changes

Behaviour the user explicitly asked for: *it's okay if cars get stuck, but creating new roads should unblock them*.

Two low-effort mechanisms, in order of preference:

1. **Already present: `pending_repath` at leg end.** Every time a building pair is re-evaluated in `recompute`, surviving cars flip `pending_repath = true`. Make `plan_next_leg` use `best_road_path` (already does). New roads get picked up at the next leg rollover.
2. **Add: stall-triggered repath.** If a car has been clamped below `CROSSOVER_THRESHOLD` for more than `STALL_TICKS_BEFORE_REPATH = 180` consecutive ticks (~3 seconds at 60 FPS), force a mid-leg repath:
   - From its current tile to the current leg's goal tile, via `RoadPathfinder#find_path`.
   - If a different path exists, adopt it (`step_index = 0`, `progress = 0.0`, same direction).
   - If no alternate path exists, reset the stall counter but keep waiting. Don't despawn — the user explicitly said getting stuck is acceptable.
   - When a new road is placed, the pathfinder will return a different route on the next stall check, so adding roads genuinely unblocks jammed cars.

Track the stall counter as `car[:stall_ticks]`. Reset it to `0` any tick the car actually advances (progress moves without being clamped).

### 6. Rendering is unaffected

No changes to `render`. The occupancy system only influences `advance_car` and `spawn_new_car`. Cars that are clamped simply render at the same interpolated position as last tick — which looks like the car waiting, which is the desired visual.

### 7. Keep randomness out

Do not introduce RNG for arbitration. Determinism helps debugging phantom jams and matches how the rest of the sim (A* tiebreaks, tile_order) already works.

## File Changes

### Updated files

- `mygame/app/car_manager.rb`
  - Add `TILE_CAPACITY`, `CROSSOVER_THRESHOLD`, `STALL_TICKS_BEFORE_REPATH` constants.
  - Add occupancy-map rebuild at the top of `tick`.
  - Replace single-line `progress += speed` with gated advance (capacity + right-hand yield).
  - Add spawn guard in `spawn_new_car`.
  - Add `car[:stall_ticks]` to car shape; increment on clamp, reset on advance; trigger mid-leg repath at threshold.
- `mygame/app/game_state.rb`
  - Initialise `state.car_occupancy ||= {}`.

### Files deliberately NOT touched

- `road_graph.rb`, `road_pathfinder.rb` — pathfinding stays traffic-agnostic. Traffic is layered on top.
- `building_placer.rb`, `road_builder.rb`, `input_handler.rb` — unchanged.
- Rendering code in `render` — unchanged.

## Acceptance Criteria

1. Two cars travelling opposite directions on the same straight road coexist on adjacent tiles without visually overlapping on the same tile (two-per-tile cap respected during crossover).
2. A third car approaching a tile that already has two cars clamps at the approach side until capacity frees up.
3. At a 4-way intersection with two contending cars, the car whose counterpart is on its **right** yields, and the other crosses first. Reversing the scenario reverses the outcome.
4. Cars never spawn on top of existing traffic at full tiles; the spawn is deferred instead.
5. Running traffic for several minutes produces visible slow-down clusters (phantom jams) without any explicit jam logic.
6. When a jam leaves a car stalled, placing an additional road that enables an alternate route causes the stalled car to re-route and resume motion within a few seconds.
7. No car becomes permanently invisible, duplicated, or stuck on a non-road tile as a side effect of the new arbitration.

## Validation Steps

1. Build a long straight road with two buildings at the ends. Confirm two cars pass each other cleanly and never share a tile beyond the capacity cap.
2. Build a narrow road between three buildings so their pair-cars funnel through a shared segment. Observe that waits propagate backwards (phantom jam) and that no car clips through another.
3. Build a 4-way crossroad and place buildings such that two cars routinely arrive at the centre tile on the same tick. Confirm the right-hand yield fires and the loser waits. Rotate the scenario 90° and confirm the rule still holds.
4. Intentionally create a bottleneck so a car stalls for ~3 seconds. Add an alternate road that offers a new route. Confirm the stalled car switches paths and resumes within a few ticks.
5. Let the sim run for 5+ minutes on a dense map. Confirm no crashes, no cars occupying non-road tiles, and no permanent gridlock (jams should eventually clear as building-pair flows shift).
6. Spam the reset button mid-jam and confirm occupancy and stall counters are cleared along with the rest of the state.
