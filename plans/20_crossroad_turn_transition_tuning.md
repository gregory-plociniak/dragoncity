# Plan: Fine-Tune Crossroad Turn Direction Switching

## Goal

Make cars turn through a `:cross` tile without the current visual snap at the segment boundary.

The result should:

1. keep straight driving unchanged,
2. remove the sideways "jump" when a car changes from its incoming lane to its outgoing lane,
3. make the facing-direction switch tunable instead of hard-coded to the exact `step_index` rollover,
4. expose a small set of constants that can be adjusted by eye.

## Current State

- `CarMotion#advance` moves a car along one segment until `progress >= 1.0`, then increments `step_index` and starts the next segment at `progress = 0.0`.
- `CarRenderer#enqueue_world` derives both:
  - the sprite direction via `sprite_for_delta(delta_col, delta_row)`,
  - the lane offset via `lane_offset_for(path, step_index, progress)`.
- `lane_offset_for` currently ignores `progress` and returns the full offset for the current segment only.
- On a turn like `A -> X -> B`, where `X` is a `:cross` tile:
  - the car uses the full incoming direction and lane offset for the entire `A -> X` segment,
  - then on the next tick it uses the full outgoing direction and lane offset for the `X -> B` segment.

That means the car's centerline is continuous, but its rendered pose is not. The visible snap comes from the renderer changing both the facing sprite and the lane offset at the exact moment the segment changes.

## Problem

The crossroad turn has no transition window.

Two separate things switch too late and too abruptly:

1. **Lane offset**
   The car stays locked to the incoming segment's right-hand lane until the moment it reaches the crossroad center, then instantly jumps to the outgoing segment's right-hand lane.

2. **Facing sprite**
   The car keeps the incoming sprite until `step_index` rolls over, then flips to the outgoing sprite in one frame.

This is why turns look wrong even though movement, gating, and stop-control are otherwise working as intended.

## Design Overview

Add a small, explicit **crossroad turn presentation model** in the renderer.

For cars that are turning through a `:cross` tile, compute a normalized **turn phase** that begins near the end of the incoming segment and ends shortly after entering the outgoing segment. Use that phase to:

1. blend the lane offset from the incoming direction to the outgoing direction,
2. switch the facing sprite at a tunable point inside that blend window,
3. optionally extend later to curve the rendered path if the lane-offset blend alone is not enough.

Important scope choice:

- This plan changes **presentation**, not pathfinding, collision gates, or all-way-stop ownership.
- The car still follows the same tile path and the same occupancy rules.
- The first pass should not touch `CarMotion` unless a tiny helper is needed to preserve turn context across the segment rollover.

## Implementation

### 1. Detect "turning through a crossroad"

Add a helper that inspects three consecutive path points:

```ruby
from = path[idx]
via = path[idx + 1]
to = path[idx + 2]
```

Return turn context only when:

- all three points exist,
- `RoadGraph.road_kind_at(roads, via[0], via[1]) == :cross`,
- the inbound delta and outbound delta differ.

Recommended helper location:

- `CarGeometry.crossroad_turn_context(roads, car)`

Suggested return shape:

```ruby
{
  crossroad: via,
  inbound_delta: [via[0] - from[0], via[1] - from[1]],
  outbound_delta: [to[0] - via[0], to[1] - via[1]]
}
```

This keeps turn detection out of `CarRenderer#enqueue_world` and makes the logic reusable for both offset and sprite choice.

### 2. Introduce tunable turn-window constants

Add presentation constants in `car_renderer.rb`:

```ruby
TURN_BLEND_IN_START_PROGRESS = 0.72
TURN_BLEND_OUT_END_PROGRESS = 0.28
TURN_SPRITE_SWITCH_PHASE = 0.58
```

Meaning:

- `TURN_BLEND_IN_START_PROGRESS`:
  start blending before the car reaches the crossroad center on the incoming segment.
- `TURN_BLEND_OUT_END_PROGRESS`:
  finish blending shortly after the car enters the outgoing segment.
- `TURN_SPRITE_SWITCH_PHASE`:
  the point inside the full turn phase where the car starts using the outgoing-facing sprite.

These are the main user-facing tuning knobs.

### 3. Compute a normalized turn phase across the segment boundary

The renderer needs a single `0.0..1.0` phase that spans both sides of the turn:

- on the incoming segment:
  - before `TURN_BLEND_IN_START_PROGRESS` => phase is `0.0`
  - between `TURN_BLEND_IN_START_PROGRESS` and `1.0` => phase maps from `0.0` to `0.5`
- on the outgoing segment:
  - between `0.0` and `TURN_BLEND_OUT_END_PROGRESS` => phase maps from `0.5` to `1.0`
  - after `TURN_BLEND_OUT_END_PROGRESS` => phase is `1.0`

The simplest way to support the outgoing half is to detect two cases:

1. the car is still on the incoming segment and has a valid `idx + 2`,
2. the car has just rolled onto the outgoing segment and should still remember the immediately previous crossroad turn.

There are two reasonable implementations:

- **Preferred:** store a tiny transient render field on the car, for example:
  - `car[:recent_crossroad_turn] = { crossroad:, inbound_delta:, outbound_delta: }`
  - clear it once `progress > TURN_BLEND_OUT_END_PROGRESS`
- **Alternative:** reconstruct it from `path[idx - 1], path[idx], path[idx + 1]` when the car is on the outgoing segment.

Prefer the reconstruction approach first if it stays simple; only add transient car state if the indexing becomes brittle.

### 4. Blend lane offsets instead of switching them

Replace the current segment-only offset logic with a turn-aware version.

Today:

```ruby
def lane_offset_for(path, step_index, progress)
  from = path[step_index]
  to = path[step_index + 1]
  total_direction_offset(to[0] - from[0], to[1] - from[1])
end
```

Target shape:

```ruby
def lane_offset_for(roads, car)
  # straight segment => existing direction offset
  # crossroad turn => lerp(inbound_offset, outbound_offset, turn_phase)
end
```

For a turning car:

1. compute the incoming offset from `inbound_delta`,
2. compute the outgoing offset from `outbound_delta`,
3. linearly interpolate the two using `turn_phase`.

This is the core fix for the visible lateral jump.

### 5. Switch the facing sprite on phase, not on segment index

The sprite direction should not be tied directly to the currently active segment during a turn.

Recommended behavior:

- `turn_phase < TURN_SPRITE_SWITCH_PHASE` => use inbound sprite,
- `turn_phase >= TURN_SPRITE_SWITCH_PHASE` => use outbound sprite.

This keeps the four existing directional sprites and avoids new art requirements.

Even though the sprite still changes in one step, the change happens inside a broader lane-blend window, so it reads as a turn instead of a pop at the center point.

### 6. Thread roads/context into the renderer cleanly

`CarRenderer#enqueue_world` currently only receives `cars`, `camera`, and `queue`.

To detect `:cross` turns cleanly, update the render call chain:

- `CarManager#enqueue_world(args, camera, queue)`
- `@renderer.enqueue_world(args.state.cars, args.state.roads, camera, queue)`

That is enough context for `CarRenderer` or `CarGeometry` to determine whether the current path segment is part of a crossroad turn.

### 7. Keep the base movement path unchanged in phase 1

Do not change:

- `CarMotion#advance`
- `TrafficGates`
- `AllWayStopController`
- the actual tile-to-tile interpolation in `interpolated_screen_position`

First verify whether blended lane offsets plus a delayed sprite switch fully solve the visual issue.

This keeps the first implementation low-risk and makes the tuning constants meaningful.

### 8. Phase 2 fallback if the centerline still looks too angular

If the pop is improved but the turn still feels too sharp, add a second rendering-only refinement:

- use a quadratic Bezier or equivalent 3-point interpolation for cars that are turning through a `:cross`,
- keep the logical `progress` and slot occupancy unchanged,
- only curve the rendered screen-space position between:
  - the late incoming segment,
  - the crossroad center,
  - the early outgoing segment.

Suggested extra knob if needed:

```ruby
TURN_CURVE_PULL = 0.35
```

This should be a follow-up inside the same task only if phase 1 is still visibly wrong after manual tuning.

## File Changes

### Updated files

- `mygame/app/car_renderer.rb`
- `mygame/app/car_manager.rb`
- `mygame/app/car_geometry.rb`

### Optional updated files

- `mygame/app/car_motion.rb` only if a tiny transient render-context field is the cleanest way to span the outgoing half of the turn window.

## Verification

### Syntax

Run:

```text
ruby -c mygame/app/car_renderer.rb
ruby -c mygame/app/car_geometry.rb
ruby -c mygame/app/car_manager.rb
```

### In game

1. Build a single 4-way crossroad and route one car straight through it.
   Straight movement should look unchanged.
2. Route one car through a 90° turn at that crossroad.
   The car should no longer jump sideways at the center tile.
3. Adjust:
   - `TURN_BLEND_IN_START_PROGRESS`
   - `TURN_BLEND_OUT_END_PROGRESS`
   - `TURN_SPRITE_SWITCH_PHASE`
   until the turn reads naturally with the current sprite art.
4. Repeat the turn test from all four approach directions.
   The tuning should not only work for one quadrant.
5. Repeat with an all-way-stop crossroad.
   The car should still stop at the same place and resume without clipping into another lane.

## Success Criteria

- Cars no longer visibly "teleport" from incoming lane offset to outgoing lane offset at crossroad center.
- The sprite direction change is perceptibly part of the turn, not a one-frame pop caused by `step_index` rollover.
- Straight segments render exactly as before.
- The turn timing can be fine-tuned by editing a few constants instead of changing core movement code.
