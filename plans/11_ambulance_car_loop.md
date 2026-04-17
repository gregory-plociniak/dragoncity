# Plan: Spawn Ambulance Car That Drives in a Loop Between Two Buildings

## Objective
When two buildings are placed on the grid and they are separated by at least 4 tiles, spawn an ambulance car that continuously drives in a loop between them. The car sprite must match the direction it is currently traveling, using one of the four sprites in `mygame/sprites/ambulance_*.png`.

## Sprite Inventory
Four direction-specific sprites already exist:
- `sprites/ambulance_NE.png` — traveling along +col (visually up-right)
- `sprites/ambulance_SW.png` — traveling along -col (visually down-left)
- `sprites/ambulance_NW.png` — traveling along +row (visually up-left)
- `sprites/ambulance_SE.png` — traveling along -row (visually down-right)

These align with the existing road orientations (`:ne`, `:nw`) in `road_builder.rb`, so the car's direction can be expressed with the same axis conventions.

## Current Behavior
- Buildings are tracked in `args.state.buildings` as a hash keyed by `"col,row"` (see `game_state.rb:4`).
- `building_placer.rb` adds/removes entries in this hash on click.
- There is currently no concept of moving entities (cars) in the codebase. `grid_renderer.rb` only renders static ground, roads, road previews, and buildings.

## Proposed Changes

### 1. Add car state to `game_state.rb`
Add a new state entry to hold active cars:

```ruby
state.cars ||= []
```

Each car will be a hash describing its route and current progress:

```ruby
{
  path: [[col, row], [col, row], ...],  # tile-by-tile loop path
  step_index: 0,                        # which segment (from -> to) the car is on
  progress: 0.0,                        # 0.0..1.0 interpolation between current and next tile
  speed: 0.02                           # fraction of a tile advanced per tick
}
```

### 2. Add `CarManager` in `mygame/app/car_manager.rb`
A new collaborator responsible for:

1. **Detecting eligible building pairs.** After a building is placed or removed, recompute the car list. Two buildings `(c1, r1)` and `(c2, r2)` are eligible when their Chebyshev distance `max(|c1 - c2|, |r1 - r2|)` is at least 4.
2. **Building a loop path.** Use an L-shaped path between the two buildings: walk along the col axis first, then along the row axis, then back along the row axis, then back along the col axis, producing a closed loop of tile coordinates.
3. **Advancing cars each tick.** Increment `progress` by `speed`; when it reaches `1.0`, move to the next segment in the path (wrapping to `0` to form a loop).
4. **Computing the current screen position.** Interpolate between `path[step_index]` and `path[(step_index + 1) % path.size]` using `camera.world_to_screen` for both endpoints, then lerp.
5. **Picking the sprite.** From the delta `(to_col - from_col, to_row - from_row)` select:
   - `(+1, 0)` → `ambulance_NE.png`
   - `(-1, 0)` → `ambulance_SW.png`
   - `(0, +1)` → `ambulance_NW.png`
   - `(0, -1)` → `ambulance_SE.png`

Public API:
```ruby
class CarManager
  def recompute(state)     # rebuilds state.cars from state.buildings
  def tick(state)          # advances progress of each car
  def render(args, camera) # draws each car at its interpolated position
end
```

### 3. Wire `CarManager` into `main.rb`
- Require `app/car_manager.rb`.
- Instantiate `$car_manager = CarManager.new` in `initialize_runtime_objects`.
- In `tick`, call `$car_manager.tick(args.state)` before rendering and `$car_manager.render(args, $camera)` after `$grid_renderer.render`. This keeps cars drawn on top of the tile layer.

### 4. Trigger recomputation when buildings change
In `building_placer.rb`, after each successful add/delete in `handle_click`, call `$car_manager.recompute(args.state)`. Recomputing is simple and infrequent (only on click), so full rebuilds are acceptable and avoid stale car state after a building is removed.

### 5. Rendering details
Use the same approximate sprite size as buildings (`133x127`) for the ambulance, centered horizontally on the tile and offset vertically similar to `BUILDING_TILE_Y_OFFSET` so the car visually sits on the tile. Interpolate screen x/y between successive tiles' screen coordinates rather than grid coordinates so the motion looks smooth in isometric space.

## Validation Steps
1. Start the game and switch to build mode.
2. Place two buildings that are fewer than 4 tiles apart. Confirm no ambulance appears.
3. Place a second building at least 4 tiles away from an existing one. Confirm an ambulance spawns and begins driving on a rectangular loop between them.
4. Observe that the sprite changes between `ambulance_NE`, `ambulance_SE`, `ambulance_SW`, and `ambulance_NW` as the car turns each corner, matching the direction of travel.
5. Delete one of the two buildings. Confirm the ambulance disappears.
6. Place a third building at least 4 tiles from both existing buildings and confirm additional cars spawn for each eligible pair (or scope to just the first pair if multi-car support is out of scope — document which behavior is chosen).
7. Confirm the car motion does not interfere with pan, build, or road modes.
