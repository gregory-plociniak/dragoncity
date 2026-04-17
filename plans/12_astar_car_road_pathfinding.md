# Plan: A* Road Pathfinding For Cars

## Goal

Replace the current rectangle-based car loop with road-aware pathfinding so cars move only along placed roads and choose their own route between buildings.

## Current State

- `mygame/app/car_manager.rb` currently ignores `state.roads` and builds a rectangular loop directly from the two building coordinates.
- Cars are recomputed only when buildings change.
- Roads are stored in `args.state.roads` as `"col,row" => :ne | :nw | :cross`.
- A building can only be placed next to a road, so every building should have at least one candidate road-access tile.

## Implementation

### 1. Add a road-graph helper

Create a dedicated helper, for example `mygame/app/road_graph.rb`, that converts `state.roads` into traversable neighbors.

- Interpret road kinds using the existing drawing rules:
  - `:ne` connects left/right neighbors on the same row.
  - `:nw` connects up/down neighbors on the same column.
  - `:cross` connects all four orthogonal neighbors.
- Expose helpers such as:

```ruby
road_neighbors(roads, col, row) # => [[next_col, next_row], ...]
road_tile?(roads, col, row)
building_access_tiles(roads, col, row) # adjacent road tiles usable by a car
```

- Only return a neighbor when both the current tile and the neighbor support travel across that shared edge. This prevents cars from entering a tile through a direction the sprite/data does not support.

### 2. Add an A* pathfinder

Create `mygame/app/road_pathfinder.rb` with a single responsibility: find the shortest road path between two road tiles.

Suggested API:

```ruby
class RoadPathfinder
  def find_path(roads, start_tile, goal_tile)
    # returns [[col, row], [col, row], ...] or nil
  end
end
```

Algorithm details:

- Use A* with:
  - `g_score`: steps traveled so far.
  - `h_score`: Manhattan distance `|dc| + |dr|` because movement is orthogonal.
  - `f_score = g + h`.
- Track `came_from` to rebuild the final path.
- Return `nil` when no route exists.
- Keep the implementation deterministic by breaking score ties in a stable way, for example by sorting candidates by `[f_score, g_score, row, col]`.

### 3. Resolve building endpoints onto the road network

Cars should not pathfind from building tiles directly because buildings occupy non-road tiles. Instead, for each building:

- Gather all orthogonally adjacent road tiles.
- Treat those tiles as possible entry/exit anchors.
- For a building pair, evaluate every `start_access x goal_access` combination and keep the shortest valid A* result.

This avoids hard-coding one road side and lets cars still work when a building touches multiple roads.

### 4. Replace the loop builder in `CarManager`

Refactor `mygame/app/car_manager.rb` so route generation becomes road-driven.

- Remove `build_loop_path`.
- Inject or instantiate `RoadPathfinder`.
- For each eligible building pair:
  - Resolve access tiles for both buildings.
  - Find the best road path between them.
  - Skip the pair if no connected road path exists.

For the first version, keep motion simple:

- Build a shuttle loop by taking the forward path and then reversing it back to the start.
- Example:

```ruby
forward = [[2, 3], [3, 3], [4, 3], [4, 4]]
looped  = forward + forward.reverse[1...-1]
```

This preserves the existing `step_index` / `progress` animation model without requiring a separate return-path search.

### 5. Recompute cars when roads change

The current code only calls `$car_manager.recompute(args.state)` from `BuildingPlacer`. That is not enough once cars depend on roads.

Update `mygame/app/road_builder.rb`:

- After `commit_preview(state)` changes `state.roads`, trigger car recomputation.
- Recompute only when at least one preview road was committed.

Keep the existing recompute hook in `mygame/app/building_placer.rb` for building add/remove.

### 6. Preserve or reset car progress safely

Keep the current `preserve_progress_or_new` idea, but key it off the final computed path.

- If the exact path still exists after recomputation, keep `step_index` and `progress`.
- If the path changed because the road network changed, create a new car starting at the beginning of the route.
- If a building pair is no longer connected by road, remove that car entirely.

### 7. Keep rendering mostly unchanged

The rendering code in `CarManager#render` can stay close to the current version.

- Continue interpolating between successive path tiles in screen space.
- Continue choosing the ambulance sprite from the delta between consecutive tiles.
- No `GridRenderer` changes are required unless you want extra debug overlays for the chosen path.

## File Changes

### New files

- `mygame/app/road_graph.rb`
- `mygame/app/road_pathfinder.rb`

### Updated files

- `mygame/app/main.rb`
  - require the new helper/pathfinder files.
- `mygame/app/car_manager.rb`
  - swap rectangle-loop generation for road-path generation.
- `mygame/app/building_placer.rb`
  - keep recomputing cars after building changes.
- `mygame/app/road_builder.rb`
  - recompute cars after committed road edits.

## Acceptance Criteria

1. Cars only move on tiles that contain valid road connections.
2. If two buildings are near roads but their road networks are disconnected, no car is spawned for that pair.
3. If a new road segment connects two previously disconnected building areas, a car appears after the road is committed.
4. If a road segment is changed so the route breaks, the affected car disappears on the next recompute.
5. At intersections, the chosen route follows the shortest available road path.
6. Car movement and sprite direction remain smooth while following the computed path.

## Validation Steps

1. Build two buildings next to the same straight road and confirm the car follows that road instead of cutting across the map.
2. Build two buildings near disconnected road islands and confirm no car appears.
3. Add the missing connecting road and confirm a car appears immediately after mouse release commits the road.
4. Create two possible routes with different lengths and confirm the shorter one is chosen.
5. Delete or reroute a critical road tile and confirm the car path updates or disappears accordingly.
