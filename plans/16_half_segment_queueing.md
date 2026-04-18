# Plan: Half-Segment Queueing to Prevent Tail-End Collisions

## Goal

Stop two cars from visually overlapping when they queue behind a stopped car. Under plan 15's `TILE_CAPACITY = 2` rule, a follower legally enters a tile already holding a stopped leader, advances to the identical clamp position on the same segment, and renders on top of it.

Fix it by splitting each segment into two half-slots of capacity one, and adding a second gate at the segment boundary so a follower clamps visually behind the leader instead of driving into it.

## Current State

- `mygame/app/car_manager.rb` implements plan 15 with:
  - `TILE_CAPACITY = 2`, `CROSSOVER_THRESHOLD = 0.5`, `CROSSOVER_EPSILON = 0.001`.
  - `build_occupancy` keys by whole tile; `current_tile(car)` returns `path[idx]` when `progress < 0.5`, otherwise `path[idx + 1]`.
  - `resolve_crossings` fires **one** gate per segment, at the midpoint: `crossing_intent` only triggers when `progress < 0.5` and `progress + speed >= 0.5`.
  - `advance_car` clamps denied cars at `CROSSOVER_THRESHOLD - CROSSOVER_EPSILON ≈ 0.499`.
- Lane offsets (plan 14) separate opposite-direction cars visually, so the overlap bug is specifically **same-direction** queueing.

## Problem

Scenario: straight road `A - B - C` with tile C full.

1. Car 1 is on segment `B → C`, progress `0.499`, clamped (denied into C). `current_tile(Car 1) = B` because progress `< 0.5`. Visually at the B/C midpoint.
2. Car 2 is on segment `A → B`, progress `0.3`. At progress `0.5` the midpoint gate checks B: occupancy is 1 (Car 1), capacity is 2 — **allowed**. Car 2 crosses in.
3. Car 2 keeps advancing: progress `1.0` → `step_index++` → now on segment `B → C`, progress `0`. `current_tile(Car 2) = B` (progress `< 0.5`).
4. Car 2 tries to cross at progress `0.5` on `B → C`: C is still full → denied → clamps at `0.499`.
5. Car 1 and Car 2 are now **both** at progress `0.499` on segment `B → C`. Same segment, same progress, identical interpolated screen position → visible overlap.

The midpoint gate alone can't catch this: the follower's tile-entry was legitimate, and there is no second gate controlling the follower from stepping onto the already-occupied segment.

## Design

### Conceptual model

Replace the whole-tile capacity-2 rule with **per-segment-half capacity-1 slots** for the gating logic. A directed segment `S = (from_tile, to_tile)` carries two slots:

- `S.first` — progress `0.0 ≤ p < 0.5` (visually from `from_tile` center to the tile edge).
- `S.second` — progress `0.5 ≤ p < 1.0` (visually from the edge to `to_tile` center).

Each half-slot holds **at most one car**. Two cars may share the same segment only if one is in `S.first` and the other in `S.second`.

A car's occupancy key is derived from `(segment, half)`, not whole-tile.

### Two gates per segment

For a car on segment `S` moving toward segment `S'`:

- **Gate 1 — midpoint** (existing, at `p = 0.5`): move from `S.first` to `S.second`. Denied if `S.second` is occupied by another car, OR if an intersection yield (see below) rules against it.
- **Gate 2 — step boundary** (new, at `p = 1.0`): `step_index++` hops from `S.second` to `S'.first`. Denied if `S'.first` is occupied by another car.

When denied:

- Gate 1 denial → clamp progress at `0.5 - CROSSOVER_EPSILON` (unchanged behaviour, just per-slot instead of per-tile).
- Gate 2 denial → clamp progress at `1.0 - CROSSOVER_EPSILON` on the current segment. Do **not** increment `step_index`. Visually the follower stops at the next tile's center, half a tile behind a leader clamped at `0.499` on `S'`.

### Right-hand yield still applies — at both gates

- Gate 1 contention: two cars on different incoming segments to the same tile both trying to cross `0.5` and enter `S_i.second`. Different slots, so no slot collision — the existing tile-capacity-driven yield does not fire. Drop tile-capacity from the model. Yield at Gate 1 only fires when two distinct segments merge into the same downstream slot (which does not happen at Gate 1 — each segment's `.second` is distinct). In practice Gate 1 yield becomes a no-op under slot-capacity rules; keep the logic path but expect it to rarely trigger.
- Gate 2 contention: two cars finishing different segments on the same tick both want to enter the same `S'.first`. E.g. car on `(W→B)` and car on `(E→B)` both planning to step onto `(B→N)`. Apply **existing `rank_by_right_hand_yield`** unchanged — the approach-direction vectors are already what it compares.

This is where the right-hand rule now lives primarily. Gate 2 is the true intersection arbiter.

### Drop `TILE_CAPACITY`

`TILE_CAPACITY = 2` is superseded. Per-half-slot capacity 1 gives the same feeling (two cars may coexist on a road segment, one ahead, one behind) while preventing the specific overlap bug. Keeping both rules would be redundant and potentially contradictory.

Remove the constant and the `occupancy[path[0]] >= TILE_CAPACITY` spawn guard. Replace spawn guard with: defer if **the first slot** the spawned car would occupy (segment `path[0] → path[1]`, half `.first`) is taken.

### Stall / repath behaviour is preserved

`car[:stall_ticks]`, `STALL_TICKS_BEFORE_REPATH`, and `try_mid_leg_repath` stay as-is. A car clamped at either gate counts as stalled (progress not advancing through the gate). Reset stall on any tick where the car actually crosses a gate.

## Implementation

All changes are confined to `car_manager.rb` (and a tiny rename/refresh in `game_state.rb`).

### 1. Occupancy keyed by segment-half

Replace `build_occupancy` with a slot map:

```ruby
# state.car_slot_occupancy = { [from_col, from_row, to_col, to_row, half] => car }
# half ∈ [:first, :second]
```

```ruby
def build_slot_occupancy(cars)
  occupancy = {}
  cars.each do |car|
    slot = current_slot(car)
    occupancy[slot] = car if slot
  end
  occupancy
end

def current_slot(car)
  path = car[:leg][:path]
  idx = car[:step_index]
  from = path[idx]
  to = path[idx + 1]
  return nil unless from && to

  half = car[:progress] < CROSSOVER_THRESHOLD ? :first : :second
  [from[0], from[1], to[0], to[1], half]
end
```

A car parked at the end of its leg (`idx == path.size - 1`) has no outgoing segment. Keep a fallback slot keyed on the **incoming** segment's `.second` so followers still see it (e.g. `[prev_col, prev_row, from_col, from_row, :second]` when `step_index > 0`). If it truly has no prior step (spawn-point stationary), use a degenerate key `[col, row, col, row, :second]` — it's an occupancy record, not a navigation target, so shape doesn't matter as long as it's unique per tile.

### 2. Gate 1 — midpoint (rewrite of existing `crossing_intent` / `resolve_crossings`)

Intent captures the target slot `S.second` of the car's current segment:

```ruby
def midpoint_intent(car)
  path = car[:leg][:path]
  idx = car[:step_index]
  from = path[idx]
  to = path[idx + 1]
  return nil unless from && to
  return nil unless car[:progress] < CROSSOVER_THRESHOLD
  return nil unless car[:progress] + car[:speed] >= CROSSOVER_THRESHOLD

  {
    car: car,
    target_slot: [from[0], from[1], to[0], to[1], :second],
    from_tile: from,
    to_tile: to
  }
end
```

Denial: target slot already occupied by any car that is not `intent[:car]`.

Right-hand yield at Gate 1: group intents by `target_slot`. Because each directed segment's `.second` slot is unique per segment, groupings > 1 only happen for cars already on the same segment (impossible: slot was their current slot pre-tick) — so Gate 1 yield is effectively inactive. Keep the grouping code but expect `group.size == 1` almost always.

### 3. Gate 2 — step boundary (new)

Intent fires for cars whose `progress + speed >= 1.0` AND whose `step_index + 1 < path.size - 1` (i.e. there is a next segment to step onto).

```ruby
def step_intent(car)
  path = car[:leg][:path]
  idx = car[:step_index]
  from = path[idx]
  to = path[idx + 1]
  next_to = path[idx + 2]
  return nil unless from && to && next_to
  return nil unless car[:progress] >= CROSSOVER_THRESHOLD # only triggers from .second
  return nil unless car[:progress] + car[:speed] >= 1.0

  {
    car: car,
    target_slot: [to[0], to[1], next_to[0], next_to[1], :first],
    from_tile: to,                      # the tile being exited-through
    to_tile: next_to,                   # the tile being entered next
    approach_from: from                 # used for right-hand yield direction
  }
end
```

Resolve all step intents together: group by `target_slot`. For groups > 1, apply `rank_by_right_hand_yield` using approach vectors `(to - approach_from)` (same direction math as today). Denied cars clamp at `1.0 - CROSSOVER_EPSILON`.

Edge case: the end of a leg (`step_index == path.size - 2`, no `next_to`). Keep existing `plan_next_leg` logic; at that point the car has no onward slot to reserve. Allow the step so the leg can roll over.

### 4. Combined tick order

```ruby
def tick(state)
  state.car_slot_occupancy = build_slot_occupancy(state.cars)
  midpoint_denied = resolve_midpoint_crossings(state.cars, state.car_slot_occupancy)
  step_denied     = resolve_step_crossings(state.cars, state.car_slot_occupancy)

  survivors = []
  state.cars.each do |car|
    survivors << car if advance_car(state, car, midpoint_denied.include?(car), step_denied.include?(car))
  end
  state.cars = survivors
end
```

`advance_car` becomes:

```ruby
def advance_car(state, car, midpoint_denied, step_denied)
  if midpoint_denied
    clamp_below_midpoint(car)
    record_stall(state, car)
    return true
  end

  if step_denied
    clamp_below_step(car)
    record_stall(state, car)
    return true
  end

  car[:progress] += car[:speed]
  car[:stall_ticks] = 0
  while car[:progress] >= 1.0
    car[:progress] -= 1.0
    car[:step_index] += 1
    next if car[:step_index] < car[:leg][:path].size - 1

    next_leg = plan_next_leg(state.roads, car)
    return false unless next_leg
    car[:leg] = next_leg
    car[:step_index] = 0
    car[:pending_repath] = false
  end
  true
end

def clamp_below_midpoint(car)
  car[:progress] = [car[:progress] + car[:speed], CROSSOVER_THRESHOLD - CROSSOVER_EPSILON].min
end

def clamp_below_step(car)
  car[:progress] = [car[:progress] + car[:speed], 1.0 - CROSSOVER_EPSILON].min
end
```

`record_stall` encapsulates the existing `stall_ticks` increment and `try_mid_leg_repath` trigger.

### 5. Spawn guard

Replace the whole-tile check with a first-slot check:

```ruby
def spawn_new_car(roads, endpoints, key, slot_occupancy)
  path = best_road_path(roads, endpoints[0], endpoints[1])
  return nil unless path
  return nil if path.size < 2

  spawn_slot = [path[0][0], path[0][1], path[1][0], path[1][1], :first]
  return nil if slot_occupancy[spawn_slot]

  # ... existing car hash
end
```

Thread `slot_occupancy` through `recompute` (rename the current `projected_occupancy` local to match).

### 6. Remove `TILE_CAPACITY`

Delete the constant. Search-and-remove references. It should only appear in the old `resolve_crossings` / `spawn_new_car`; both are being rewritten.

### 7. State rename

- Rename `state.car_occupancy` → `state.car_slot_occupancy` in `game_state.rb`.
- Update `GameState.initialize!`.
- No other files reference `state.car_occupancy` (checked via grep; if any do, update them).

## File Changes

### Updated files

- `mygame/app/car_manager.rb`
  - Remove `TILE_CAPACITY`.
  - Replace `build_occupancy` / `current_tile` with `build_slot_occupancy` / `current_slot`.
  - Replace `crossing_intent` / `resolve_crossings` with `midpoint_intent` / `resolve_midpoint_crossings` (per-slot) and new `step_intent` / `resolve_step_crossings`.
  - Rewrite `advance_car` to handle both denial flavours and new clamps.
  - Update `spawn_new_car` to check the first slot instead of tile capacity.
  - Update `tick` to compute both denial sets.
  - Helper: extract `record_stall(state, car)` for shared stall/repath path.

- `mygame/app/game_state.rb`
  - Rename `state.car_occupancy` to `state.car_slot_occupancy`.

### Files deliberately NOT touched

- `road_graph.rb`, `road_pathfinder.rb` — pathfinding stays traffic-agnostic.
- `building_placer.rb`, `road_builder.rb`, `input_handler.rb` — unchanged.
- Rendering — unchanged. The fix relies entirely on where `progress` clamps, not on visual code.

## Acceptance Criteria

1. Two cars queueing in the same direction on a straight road behind a blocked tile never render on top of each other. The follower visibly stops roughly one half-tile behind the leader.
2. Two cars travelling opposite directions on a long straight road continue to pass cleanly (lane offsets separate them; slot rules never deny opposite-direction travel on a straight segment).
3. At a 4-way intersection, two cars converging onto the same outgoing segment still resolve by right-hand yield — now via Gate 2 instead of Gate 1.
4. A third car approaching a tile that already has a queue of two stops behind them; chain length grows backwards rather than piling up.
5. Spawning never places a car on top of another car: if the first segment's first-half slot is occupied, the spawn is deferred.
6. Adding a road that opens an alternate route still unblocks stalled cars within `STALL_TICKS_BEFORE_REPATH` ticks.
7. No car renders on a non-road tile, gets duplicated, or becomes stuck permanently.

## Validation Steps

1. Build a straight road `A — road — road — road — B` and place two extra intermediate buildings to force through-traffic. Watch three cars back up behind a blocked endpoint. Confirm each pair of consecutive cars is visually separated by ~half a tile, never overlapping.
2. Repeat with opposite-direction pairs to confirm no regression in plan-14 lane separation.
3. Build a 4-way crossroad where two cars converge onto the same outgoing segment. Confirm right-hand yield fires at Gate 2 (the car on the left stops at its current segment's end, not past the intersection center).
4. Force a long queue (5+ cars) and confirm it extends backwards tile by tile, with every car clamped at `1.0 - ε` of its respective segment except the frontmost car which clamps at `0.5 - ε` of the final blocked segment.
5. Drop an alternate road mid-jam. Confirm stalled cars reroute within ~3 seconds.
6. Reset mid-jam; confirm `state.car_slot_occupancy` is cleared alongside `state.cars`.
7. Let the sim run 5+ minutes on a dense map; confirm no crashes, no orphan overlaps, no permanent gridlock.
