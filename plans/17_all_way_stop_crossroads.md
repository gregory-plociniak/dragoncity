# Plan: All-Way Stop Crossroad Control

## Goal

Change 4-way crossroads from the current rolling right-hand-yield behavior to an **all-way stop**:

1. Cars approaching a stop-controlled crossroad visibly **slow down**.
2. Cars come to a **complete stop** before entering the intersection.
3. Crossroad priority follows a simple deterministic all-way-stop rule:
   - the first car to finish stopping goes first,
   - if multiple cars finish stopping on the same tick, use the existing right-hand rule,
   - if still tied, smaller `tile_order` wins.
4. Only **one car owns the crossroad at a time**. Do not model simultaneous non-conflicting movements in the first pass.

## Assumption

The user message ended after “follow this rule”, so this plan assumes the standard all-way-stop priority above. If the intended rule differs, only the arbitration section should need to change.

## Current State

- `mygame/app/car_manager.rb` already uses slot-based movement:
  - `current_slot` maps a car to `:first` or `:second` half of a directed segment.
  - `resolve_midpoint_crossings` gates midpoint entry.
  - `resolve_step_crossings` gates segment-to-segment entry.
- Intersections currently resolve via `rank_by_right_hand_yield(group)`.
- Arbitration is local to a **target slot**, not to a whole crossroad tile.
- Cars always move at `car[:speed]` unless blocked; there is no braking or stop-line state.
- `RoadGraph` represents a 4-way crossroad as `:cross`.

## Problem

The current behavior looks like a yield sign, not a stop sign:

- Cars roll into the crossroad without a full stop.
- Priority is decided only at the moment of slot contention.
- Two cars aiming at different outgoing slots can still be evaluated independently, which is fine for yield logic but not for a simple all-way-stop model.
- Treating each outgoing slot separately makes it hard to say “this intersection is currently taken by car X”.

## Design Overview

Keep the existing half-segment occupancy model from plan 16. Add a new **crossroad controller** on top of it for `:cross` tiles:

1. Detect when a car is approaching a stop-controlled crossroad.
2. Brake the car toward a fixed **stop line** on the incoming segment.
3. Record the tick when the car first reaches a complete stop.
4. For each crossroad, choose exactly one waiting car as the current owner.
5. Only the owner may pass the step-boundary gate through that crossroad.
6. Once the owner actually enters the outgoing segment, release ownership so the next queued car can be chosen.

This replaces right-hand arbitration at 4-way crossroads, but keeps the existing midpoint/slot model and the existing right-hand helper as the tie-break for simultaneous arrivals.

## Implementation

### 1. Identify stop-controlled crossroads

Add a helper in `car_manager.rb`:

```ruby
def stop_controlled_crossroad_for(car)
  path = car[:leg][:path]
  idx = car[:step_index]
  from = path[idx]
  to = path[idx + 1]
  next_to = path[idx + 2]
  return nil unless from && to && next_to
  return nil unless road_kind_at(to[0], to[1]) == :cross

  to
end
```

Use the narrow scope deliberately:

- Only apply all-way-stop logic when the car is **entering** a `:cross` tile and also has a valid exit tile.
- Straight roads and simple turns outside a `:cross` tile keep existing behavior.

If desired later, this helper can be broadened to any intersection tile with `road_neighbors(...).size >= 3`, but that is not needed for the first pass.

### 2. Add a stop-line state to each car

Extend the car record with transient fields:

```ruby
car[:current_speed] ||= car[:speed]
car[:stop_crossroad] = [col, row] | nil
car[:stop_arrival_frame] = Integer | nil
car[:stop_go_token] = [col, row] | nil
```

Rules:

- `current_speed` is the instantaneous speed used this tick.
- `stop_crossroad` is set while the car is braking toward a specific crossroad.
- `stop_arrival_frame` is assigned once, when the car first reaches a full stop at the line.
- `stop_go_token` means this car currently owns that crossroad and may proceed once the normal slot gate is open.

Reset all of these whenever the car clears the intersection or its leg/path is replaced.

### 3. Add a visible stop line and braking behavior

Introduce tuning constants in `car_manager.rb`:

```ruby
ALL_WAY_STOP_LINE_PROGRESS = 0.8
STOP_BRAKE_PER_TICK = 0.003
STOP_ACCEL_PER_TICK = 0.004
```

Behavior on an incoming segment whose destination tile is a stop-controlled crossroad:

- Before `ALL_WAY_STOP_LINE_PROGRESS`, reduce `current_speed` each tick by `STOP_BRAKE_PER_TICK`.
- Clamp movement so the car never moves past `ALL_WAY_STOP_LINE_PROGRESS` unless it has a `stop_go_token`.
- At the stop line:
  - set `current_speed = 0.0`,
  - assign `stop_arrival_frame ||= state.frame_index`,
  - keep the car stationary until selected.
- Once the car has a go token, accelerate back toward `car[:speed]` using `STOP_ACCEL_PER_TICK`.

Notes:

- This is intentionally lightweight visual braking, not a physics model.
- The stop line is before the tile center so the car visibly waits at the approach, not inside the crossroad sprite.

### 4. Resolve crossroad ownership per tile, not per slot

Add a new resolver before `resolve_step_crossings`:

```ruby
def resolve_all_way_stops(state, cars)
  # returns a set of cars denied by stop control,
  # and updates stop_go_token on winners
end
```

Build one waiting group per crossroad tile:

- candidate cars are those with `stop_controlled_crossroad_for(car)` present,
- that have reached `ALL_WAY_STOP_LINE_PROGRESS`,
- and are not already past the stop line.

Ownership rule per crossroad:

1. If one car already has `stop_go_token` for this crossroad and has not crossed yet, keep ownership with that car.
2. Otherwise, choose the next owner from fully stopped cars:
   - smallest `stop_arrival_frame` wins,
   - ties use `rank_by_right_hand_yield`,
   - final tie uses `tile_order` of the approach tile.
3. All non-owners at that crossroad are denied for this tick.

Important scope decision:

- Arbitration is per **crossroad tile**, not per outgoing slot.
- That means one car moves through the crossroad at a time, which matches the first-pass all-way-stop behavior and avoids collision edge cases between turning movements.

### 5. Integrate stop control with the existing step gate

Current `resolve_step_crossings` is still needed for downstream slot capacity. Do not remove it.

Instead, layer the new logic in front of it:

1. `resolve_all_way_stops` decides whether a car is allowed to leave the stop line.
2. `resolve_step_crossings` still decides whether the outgoing `:first` slot is physically free.
3. A car may cross only if both conditions pass.

This gives the desired behavior:

- crossroad ownership determines **who may go**,
- slot occupancy determines **whether there is room to go**.

If the owner is allowed by stop control but the outgoing slot is still occupied, the owner keeps the go token and waits. Other cars continue to wait behind it.

### 6. Do not treat normal stop-sign waiting as a traffic jam

Current `record_stall` triggers a mid-leg repath after `STALL_TICKS_BEFORE_REPATH`.

That is correct for jams, but wrong for a normal all-way-stop queue. Update the stall rules:

- Waiting at the stop line **without** a go token does **not** increment `stall_ticks`.
- Waiting after receiving a go token but being blocked by downstream slot occupancy **does** increment `stall_ticks`.
- Any successful movement resets `stall_ticks` to `0`.

Without this change, cars queued politely at a stop sign would start rerouting away from the intersection after ~3 seconds, which would look incorrect.

### 7. Update `advance_car` to support braking and stop-line clamping

Refactor `advance_car` so movement uses an `effective_speed` instead of always using `car[:speed]`.

Recommended order:

1. Determine whether the current segment approaches a stop-controlled crossroad.
2. Update `current_speed`:
   - brake if approaching and not cleared,
   - accelerate if cleared,
   - otherwise converge back to cruise speed.
3. If the car is not cleared and would move past `ALL_WAY_STOP_LINE_PROGRESS`, clamp it there.
4. Apply midpoint and step denials as today.
5. On successful step across the crossroad boundary:
   - clear `stop_crossroad`,
   - clear `stop_arrival_frame`,
   - clear `stop_go_token`.

Keep the public method shape unchanged. The change is internal to `car_manager.rb`.

### 8. Preserve determinism

Do not add randomness.

All-way-stop priority should be deterministic across identical runs:

- arrival tick,
- right-hand tie-break,
- tile-order tie-break.

This preserves the project’s current debugging model and makes validation much easier.

## File Changes

### Updated files

- `mygame/app/car_manager.rb`
  - add stop-line helpers and constants,
  - add per-car stop state,
  - add crossroad ownership resolver,
  - integrate braking with `advance_car`,
  - exempt pre-token stop waiting from stall-triggered repath.

### Files likely unchanged

- `mygame/app/game_state.rb`
  - no persistent crossroad queue map is required if ownership is recomputed from car state each tick.
- `mygame/app/road_graph.rb`
  - existing `:cross` road kind is enough.
- rendering files
  - no dedicated rendering change is required beyond cars naturally stopping earlier on the segment.

## Acceptance Criteria

1. A car approaching a 4-way crossroad no longer rolls straight through; it visibly slows and stops before the center of the intersection.
2. If a single car reaches an empty all-way-stop crossroad, it stops briefly, then proceeds through.
3. If two cars stop at different times, the one that completed its stop first proceeds first.
4. If two cars complete their stop on the same tick, the right-hand tie-break decides the winner consistently.
5. Only one car occupies the active crossing phase of a stop-controlled crossroad at a time, even if the cars would exit through different slots.
6. Cars queued at a stop sign do not trigger mid-leg repath just because they are waiting their turn.
7. Outside `:cross` tiles, existing road-following and queueing behavior is unchanged.

## Validation Steps

1. Build a simple plus-shaped `:cross` intersection with one car approaching. Confirm it brakes, stops before the center, then continues.
2. Send two cars to the same crossroad with one arriving clearly earlier. Confirm the earlier stopped car goes first.
3. Arrange two cars to finish braking on the same tick from perpendicular approaches. Confirm the right-hand tie-break is stable when repeating the scenario.
4. Add a third and fourth car to form a full 4-way queue. Confirm they are released one at a time in deterministic order.
5. Block the winner’s outgoing segment with downstream traffic. Confirm the winner holds the intersection token, the others keep waiting, and only downstream blockage counts toward stall/repath.
6. Run the sim on a map with no crossroads. Confirm behavior is unchanged from the current implementation.
