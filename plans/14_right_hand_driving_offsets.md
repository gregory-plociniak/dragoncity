# Plan: Right-Hand Driving Lane Offsets For Cars

## Goal

Render cars slightly off the road centerline so each travel direction sits in the right-hand lane. The implementation should expose a small, centralized set of pixel offsets so the visual result can be tuned later without reworking pathfinding or animation logic.

## Current State

- `mygame/app/car_manager.rb` interpolates each car between the screen positions of two path tiles.
- The current render position is the road centerline plus a sprite-centering adjustment:
  - interpolate `sx/sy` from `camera.world_to_screen(...)`
  - draw the sprite at `x: sx - w / 2`, `y: sy - TILE_H / 2 - h / 2`
- There is no per-direction lane offset, so a car always drives through the visual middle of the road.
- Car movement already has the right primitive for this change: every visible segment has a direction delta `[(to_col - from_col), (to_row - from_row)]`.

## Problem

Driving on the centerline looks wrong once you want right-hand traffic:

- Forward and reverse legs visually reuse the same lane.
- Cars do not read as belonging to one side of the road.
- Future multi-car or denser traffic work will stack vehicles directly on top of each other.

This is a rendering/alignment problem, not a pathfinding problem. The plan should keep the road graph and A* behavior unchanged.

## Implementation

### 1. Add a dedicated lane-offset config

Keep all tuning values in one place, ideally at the top of `mygame/app/car_manager.rb` or in a tiny helper module if that reads cleaner.

Use screen-space pixel offsets, not world-space tile offsets. That makes tuning direct and predictable because the final car render already happens in screen coordinates.

Suggested shape:

```ruby
LANE_OFFSET_X = 10
LANE_OFFSET_Y = 5

RIGHT_HAND_LANE_OFFSETS = {
  [ 1,  0] => [ LANE_OFFSET_X, -LANE_OFFSET_Y], # moving visually up-right
  [-1,  0] => [-LANE_OFFSET_X,  LANE_OFFSET_Y], # moving visually down-left
  [ 0,  1] => [ LANE_OFFSET_X,  LANE_OFFSET_Y], # moving visually up-left
  [ 0, -1] => [-LANE_OFFSET_X, -LANE_OFFSET_Y]  # moving visually down-right
}.freeze
```

Those numbers are only starting guesses. The important part is that the offsets are:

- centralized
- symmetric
- keyed by movement direction
- easy to edit later

### 2. Extract centerline interpolation into a helper

Refactor the render math so the centerline position is computed first, then lane offset is applied second.

Suggested helpers:

```ruby
interpolated_screen_position(camera, from, to, progress) # => [sx, sy]
lane_offset_for(delta_col, delta_row)                    # => [dx, dy]
```

That keeps the flow explicit:

1. derive current segment
2. interpolate on the segment centerline
3. apply right-hand lane offset for that segment
4. apply sprite-centering offset

### 3. Keep sprite selection independent from lane offset

Do not couple lane placement to sprite choice.

- `sprite_for_delta` should continue to depend only on segment direction.
- `lane_offset_for` should also depend only on segment direction.
- This separation makes it easy to tune offsets without accidentally changing orientation logic.

### 4. Start with straight-segment offsets only

For the first pass, apply the current segment's offset for the entire segment:

```ruby
sx += dx
sy += dy
```

This should be enough to get visible right-hand driving quickly and gives you a clear base for fine-tuning.

### 5. Add optional corner blending if turns look too sharp

If the car appears to "snap" sideways when it reaches an intersection and turns, add one extra tuning step after the basic offsets are in place.

Suggested approach:

- Look ahead to the next segment when `car[:progress]` is near the end of the current one.
- Blend from the current segment offset to the next segment offset over a small fraction of the segment.

Example tuning knobs:

```ruby
TURN_BLEND_START = 0.75
TURN_BLEND_END   = 1.0
```

This step should stay optional. Do not introduce it unless the basic per-direction offsets visibly need it.

### 6. Make the tuning surface explicit

The point of this task is not only to add the behavior, but to make later adjustment cheap.

Include a short comment block near the constants explaining:

- which delta corresponds to which visual direction
- that the values are screen-space pixels
- that `LANE_OFFSET_X` and `LANE_OFFSET_Y` are expected to be tuned by eye

If helpful, keep the config as a hash of final `[dx, dy]` pairs instead of derived constants. That is slightly more verbose, but even easier to fine-tune direction by direction later.

### 7. Limit scope to rendering

This plan should not change:

- `RoadGraph`
- `RoadPathfinder`
- car recompute logic
- car pairing logic
- building or road placement

Only the rendered screen position of cars should move.

## File Changes

### Updated files

- `mygame/app/car_manager.rb`
  - add lane-offset constants/config
  - extract interpolation and offset helpers
  - apply directional offset before drawing the sprite

### Optional follow-up docs

- `insights/...` only if you want to capture final tuned values and the reasoning behind them after testing

## Acceptance Criteria

1. A car traveling in each of the four segment directions renders consistently to the right side of its travel direction.
2. Reversing direction places the car on the mirrored lane rather than the same centerline.
3. All offset values live in one obvious place so they can be tuned without touching pathfinding code.
4. Straight-road movement remains smooth.
5. If corner blending is not implemented in the first pass, the remaining turn snap is minor and isolated to intersections.

## Validation Steps

1. Build a long same-row road and confirm a car driving both directions sits on opposite visual sides of that road.
2. Build a long same-column road and confirm the same mirrored behavior there.
3. Add turns and crossroads, then watch the car through several loops to see whether the chosen offsets still look like right-hand traffic.
4. Tweak only the offset constants and confirm the lane placement changes immediately without requiring structural code changes.
5. If turns still look abrupt after tuning the straight offsets, implement and tune the optional corner blending step.
