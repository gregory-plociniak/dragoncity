# Plan: Repath Cars Only At Loop Endpoints

## Goal

Stop resetting car position whenever the road network changes. A car should always finish its current leg (reach the next building) and only then pick up a newly shorter route for the following leg.

## Current State

- `mygame/app/car_manager.rb` precomputes a full shuttle loop (`forward + reverse`) and stores it on the car as `:path`.
- `preserve_progress_or_new` keeps `step_index` and `progress` only when the new path is `==` the existing car's path.
- Any change to the road network that shifts the A* result produces a different `:path`, so the car is treated as new and restarted at `step_index: 0, progress: 0.0`.
- Recomputation runs from both `BuildingPlacer` and `RoadBuilder` after edits are committed.

## Problem

Because recompute replaces the path atomically:

- Adding a shortcut mid-trip snaps the car back to the start of the new route.
- Deleting an unrelated road tile can also change the A* tie-breaking and jitter the car's position.
- The "which car is which" identity is path-shaped, which is fragile.

We want identity to be **building-pair shaped** and routing decisions to happen **only at endpoints**.

## Implementation

### 1. Change car identity to the building pair

Store each car keyed by its unordered building pair instead of by its exact path.

- Introduce a stable pair key, for example `[[min_c, min_r], [max_c, max_r]]` or a string `"c1,r1|c2,r2"` with the endpoints sorted.
- Add `:pair_key` to every car record.
- In `recompute`, match existing cars by `:pair_key`, not by `:path`.

### 2. Split the loop into two legs

Replace the single combined shuttle path with an explicit leg model.

Each car record becomes roughly:

```ruby
{
  pair_key: "2,3|7,5",
  endpoints: [[2, 3], [7, 5]],  # the two buildings
  leg: { path: [...], direction: 0 }, # current leg, direction 0 = A->B, 1 = B->A
  step_index: 0,
  progress: 0.0,
  speed: DEFAULT_SPEED,
  pending_repath: false
}
```

- `leg[:path]` is a one-way road path from the current origin access tile to the destination access tile.
- The car animates along `leg[:path]` from `step_index = 0` up to the final tile.
- When it reaches the last step, it flips `direction`, recomputes the next leg, and resets `step_index` and `progress` for the new leg.

### 3. Mark road changes as pending, do not replace mid-leg

When `recompute` fires because roads or buildings changed:

- Resolve access tiles for the building pair as today.
- For every existing car found by `:pair_key`:
  - Do not touch `leg`, `step_index`, or `progress`.
  - Set `pending_repath = true` so the next leg transition uses a fresh A* result.
- For pairs that have no existing car:
  - Run A* now for the first leg (A -> B) and create a new car starting at `step_index: 0`.
- For pairs whose buildings were removed:
  - Remove the car.
- For pairs whose existing `leg[:path]` becomes invalid (a tile on the current leg is no longer a road or no longer connects in the required direction):
  - Treat this as unavoidable: recompute immediately from the car's current tile, or remove the car if no route exists from there. See step 5.

### 4. Recompute at endpoint transitions

In `tick`, when a car finishes its current leg:

- Flip `direction`.
- Compute the next leg's start and goal access tiles from `endpoints` based on the new direction.
- Run A* for the new leg.
- If `pending_repath` was set, this is where it is naturally consumed; clear the flag either way.
- If no path exists anymore, remove the car.
- Otherwise, assign the new `leg`, reset `step_index = 0`, `progress = 0.0`, and continue ticking.

Because the choice happens at the building, "drive to the next building, then pick the shorter road" falls out of this structure for free.

### 5. Handle the current leg becoming invalid

If a user deletes a road tile that the car is currently driving on, we cannot honor "finish the leg first" literally.

Detection:

- During `recompute`, validate each existing car's remaining leg path from `step_index` to the end using the current roads.
- If any upcoming edge is no longer traversable, the leg is broken.

Resolution:

- Try to plan a new leg from the car's current tile (or the previous tile it just left, whichever is safer) to the same leg destination.
- If that works, replace only the current leg; keep `direction` and endpoints.
- If it fails, remove the car. It can reappear on the next successful recompute.

Keep this branch deliberately narrow so the common case (road added elsewhere, current leg still valid) never resets the car.

### 6. Update rendering

`CarManager#render` currently reads `car[:path]` directly. Update it to read `car[:leg][:path]`.

- Interpolation between `from` and `to` stays the same.
- Sprite selection from the delta between consecutive tiles stays the same.
- No camera or grid changes.

### 7. Keep external callers unchanged

The public surface of `CarManager` (`recompute`, `tick`, `render`) should keep the same signatures. Callers in `BuildingPlacer` and `RoadBuilder` do not need to know about legs or repathing.

## File Changes

### Updated files

- `mygame/app/car_manager.rb`
  - Add pair-key identity.
  - Replace shuttle-loop path with per-leg path.
  - Defer repathing to endpoint transitions via `pending_repath`.
  - Handle broken-current-leg recovery.
  - Update `render` to use `car[:leg][:path]`.

### Not expected to change

- `mygame/app/road_graph.rb`
- `mygame/app/road_pathfinder.rb`
- `mygame/app/building_placer.rb`
- `mygame/app/road_builder.rb`
- `mygame/app/main.rb`

## Acceptance Criteria

1. Adding a shortcut road while a car is driving does not move the car. The car continues along its current leg uninterrupted.
2. When that car reaches the destination building, the next leg uses the new shorter road.
3. Adding or removing unrelated roads never changes `step_index` or `progress` of any existing car.
4. Deleting a road tile on the car's current leg does not teleport the car to a different tile; the car either continues on a repaired sub-path from where it is, or disappears cleanly.
5. New building pairs still spawn a car immediately at the start of their first leg.
6. Removed buildings still remove their associated car.

## Validation Steps

1. Create two buildings connected by a long path. While the car is mid-trip, place a shorter road parallel to the long one. Confirm the car keeps driving on the long path until it reaches the next building, then switches to the shorter path.
2. Place an unrelated road far from the car. Confirm the car's position and progress do not visibly change.
3. Delete a road tile on the segment the car has already driven past. Confirm the car keeps going and the next leg picks the new best route.
4. Delete a road tile directly in front of the car. Confirm the car either reroutes from its current tile or disappears, but does not jump backward.
5. Remove one of the two buildings. Confirm the car disappears.
6. Add a new distant building pair with a valid road connection. Confirm a new car appears starting at the beginning of its first leg.
