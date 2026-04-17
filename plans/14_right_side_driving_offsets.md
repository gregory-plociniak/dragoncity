# Plan: Right-Side Driving Offsets With Sidewalk Defaults

## Goal

Make cars render on the **right side of the road** instead of the tile centerline, while keeping enough clearance from the sidewalk so sprites do not look like they are driving on the curb. The values should be centralized so they are easy to fine tune later.

## Current State

- `mygame/app/car_manager.rb` already has road-aware pathfinding and per-segment interpolation.
- Cars currently render at the interpolated tile-center position for each road segment.
- There is no concept of lane width, curb clearance, or sidewalk-safe offset.
- Because the path data is already directional (`from -> to`), this can be added as a rendering/layout pass without changing A* or road graph traversal.

## Scope

This plan is for **lane placement and visual offsets**, not one-way traffic rules.

- Cars may still travel in both directions on the same road network.
- The change is that each direction uses the correct **right-hand lane position** on screen.
- Sidewalk handling is treated as a configurable visual buffer from the road edge.

## Proposed Approach

### 1. Add a dedicated traffic layout helper

Create a new helper, for example `mygame/app/traffic_layout.rb`, to hold all lane and sidewalk tuning values in one place.

Suggested API:

```ruby
module TrafficLayout
  def self.segment_offset(delta_col, delta_row, road_kind)
  end

  def self.clamp_for_surface(offset_x, offset_y, road_kind)
  end
end
```

Reason for a separate helper:

- Keeps `CarManager` focused on car state and motion.
- Makes the tuning values obvious and easy to edit later.
- Gives one place to add future rules for turns, intersections, or different vehicle sizes.

### 2. Start with screen-space lane offsets

Use **screen-space pixel offsets** rather than world-space offsets for the first version. That matches the current renderer and will be much easier to fine tune by eye.

Recommended default lane offsets:

```ruby
RIGHT_LANE_SEGMENT_OFFSETS = {
  [1, 0]  => [-12, -6], # moving +col
  [-1, 0] => [12, 6],   # moving -col
  [0, 1]  => [-12, 6],  # moving +row
  [0, -1] => [12, -6]   # moving -row
}.freeze
```

These values intentionally push cars off the centerline but keep them inside the road body. They are conservative defaults, not final art-tuned values.

### 3. Add sidewalk-safe surface defaults

Define small per-surface limits so cars do not visually drift into sidewalk space.

Suggested defaults:

```ruby
SURFACE_DEFAULTS = {
  ne: {
    sidewalk_buffer_px: 8,
    max_lane_shift_x: 12,
    max_lane_shift_y: 6
  },
  nw: {
    sidewalk_buffer_px: 8,
    max_lane_shift_x: 12,
    max_lane_shift_y: 6
  },
  cross: {
    sidewalk_buffer_px: 6,
    max_lane_shift_x: 10,
    max_lane_shift_y: 5
  }
}.freeze
```

Meaning of these defaults:

- `sidewalk_buffer_px`: visual curb/sidewalk clearance to preserve.
- `max_lane_shift_x/y`: hard cap so the lane offset stays inside the road sprite.
- `cross` uses a slightly smaller shift because intersections have less visual room near corners.

### 4. Clamp the offset before rendering

When rendering a segment:

1. Determine the segment direction from `to - from`.
2. Look up the base lane offset from `RIGHT_LANE_SEGMENT_OFFSETS`.
3. Read the road kind for the current tile or the tighter of the two segment tiles.
4. Clamp the offset using `SURFACE_DEFAULTS`.
5. Add the final offset to the interpolated screen position before drawing the sprite.

This keeps the current motion model intact and only changes where the car sits on the road.

### 5. Keep turns simple in v1

For the first version, do not add curved turn geometry. Use the offset of the **current segment** only.

That means:

- Straight roads get clean right-lane placement immediately.
- Intersections remain stable and readable.
- Fine tuning stays simple because there is no turn spline math yet.

If turning still looks too abrupt later, add an optional blend near segment boundaries:

```ruby
TURN_BLEND_PROGRESS = 0.25
```

That would lerp from the current segment offset to the next segment offset during the last 25% of the segment.

### 6. Add endpoint pullback near buildings

Cars currently path to road access tiles beside buildings. To avoid overlap near building fronts or sidewalks right next to building entrances, add a small pullback when a segment starts or ends at a building access tile.

Suggested default:

```ruby
ENDPOINT_PULLBACK_PX = 4
```

This should only slightly nudge the sprite away from the curb/building edge, not change the path itself.

### 7. Update `CarManager#render`

Modify `CarManager#render` so it:

- computes the current segment delta,
- asks `TrafficLayout` for the lane offset,
- applies sidewalk clamping,
- adds the resulting `(offset_x, offset_y)` to `sx` and `sy`,
- keeps the existing sprite selection and interpolation logic.

No changes should be required in:

- `RoadPathfinder`
- `RoadGraph`
- `RoadBuilder`
- `BuildingPlacer`

## Suggested Defaults To Expose For Tuning

Keep these as top-level constants in `traffic_layout.rb`:

```ruby
LANE_OFFSET_SCALE = 1.0
RIGHT_LANE_SEGMENT_OFFSETS = {
  [1, 0]  => [-12, -6],
  [-1, 0] => [12, 6],
  [0, 1]  => [-12, 6],
  [0, -1] => [12, -6]
}.freeze

SURFACE_DEFAULTS = {
  ne:    { sidewalk_buffer_px: 8, max_lane_shift_x: 12, max_lane_shift_y: 6 },
  nw:    { sidewalk_buffer_px: 8, max_lane_shift_x: 12, max_lane_shift_y: 6 },
  cross: { sidewalk_buffer_px: 6, max_lane_shift_x: 10, max_lane_shift_y: 5 }
}.freeze

ENDPOINT_PULLBACK_PX = 4
TURN_BLEND_PROGRESS = 0.25
```

`LANE_OFFSET_SCALE` gives a quick global tuning lever:

- `0.8` if cars still look too close to the center.
- `1.1` to `1.2` if you want a stronger right-lane bias.

## File Changes

### New file

- `mygame/app/traffic_layout.rb`

### Updated files

- `mygame/app/main.rb`
  - require `app/traffic_layout.rb`
- `mygame/app/car_manager.rb`
  - apply lane offsets during render
  - optionally blend offsets near turns
  - optionally apply endpoint pullback

## Acceptance Criteria

1. Cars no longer render on the road centerline during straight movement.
2. For every segment direction, the car appears on the correct right-hand side of the road.
3. Cars do not visibly overlap the sidewalk/curb area on straight road tiles.
4. Intersections still render cleanly, with cars staying inside the paved area.
5. All lane and sidewalk values can be adjusted from a single helper without rewriting render logic.

## Validation Steps

1. Spawn a car on a long straight `:ne` road and confirm it stays on one side of the road instead of the middle.
2. Spawn a car on a long straight `:nw` road and confirm the right-side offset is mirrored correctly for both travel directions.
3. Send a car through a `:cross` intersection and confirm it stays inside the road body rather than clipping into a sidewalk corner.
4. Tune `LANE_OFFSET_SCALE` down to `0.8` and up to `1.2` and confirm the visual shift changes predictably.
5. Tune `sidewalk_buffer_px` for `:cross` and confirm intersection spacing can be tightened or loosened without touching `CarManager`.
