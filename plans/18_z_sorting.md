# Plan: Z-Sorting for Isometric Sprites

## Goal

Render every sprite that lives in the isometric world (ground tiles, road tiles, road previews, buildings, cars) in a single depth-correct pass so that:

1. A building on a "back" tile never draws on top of a car passing in front of it.
2. A car currently on a tile draws above the road/ground of that same tile.
3. A car that turns onto a new tile transitions cleanly with no flicker against neighboring buildings.
4. Road previews stay above ground but below buildings and cars.
5. UI chrome (mode buttons, reset button, labels) is unaffected and always draws on top.

## Current State

- `mygame/app/main.rb` renders the world in two fixed passes per tick:
  - `$grid_renderer.render(args, $camera)` — ground, roads, previews, buildings, then UI buttons.
  - `$car_manager.render(args, $camera)` — every car afterwards.
- `GridRenderer#render` iterates `GRID_SIZE.times { |row| GRID_SIZE.times { |col| ... } }` and, per tile, pushes sprites onto `args.outputs.sprites` in this order:
  1. ground OR road,
  2. road preview (if any),
  3. building (if any).
- `CarManager#render` iterates over `state.cars` in list order and pushes one sprite per car.
- UI chrome (`render_mode_buttons`, `render_reset_button`) is pushed to `args.outputs.sprites` at the end of `GridRenderer#render` — before cars.

## Problem

Depth ordering is implicit in the emission order, not in the scene geometry:

- Because cars are emitted after all tiles, a car in the back-left of the grid still draws on top of a building in the front-right. In isometric space the building is closer to the camera and should occlude the car.
- Road previews and buildings are emitted row-by-row, so a preview on tile `(col=2, row=2)` can draw on top of a building on `(col=0, row=0)` even though the building is "in front".
- The UI buttons currently draw **before** cars, which means a car sprite can cover a mode button if one happens to render in the same screen region.
- Any new world entity (e.g. pedestrians, effects) would need bespoke emission-order logic to avoid these artifacts.

## Design Overview

Introduce a **depth-sorted render queue** for world sprites:

1. Every world sprite is staged into an in-memory list together with a numeric `depth` key instead of being pushed directly to `args.outputs.sprites`.
2. After all producers have contributed (grid, cars, future entities), the queue is sorted once by `depth` ascending and flushed to `args.outputs.sprites`.
3. UI chrome is kept out of the queue and emitted **after** the flush so it always sits on top.

Depth is derived from the sprite's **world anchor tile** `(col, row)` using the painter's-algorithm key that already holds for isometric projections:

```
depth = col + row
```

Tiles with smaller `col + row` are farther from the camera and draw first. Cars use the tile they are currently *entering* (the `to` tile of the active step), with a small fractional bias so that:

- A car on tile `(c, r)` draws above the ground/road of `(c, r)` (same depth, but inserted later in stable sort).
- A car that has crossed the midpoint toward `(c', r')` starts sorting with the new tile's depth.

Road previews use the same `col + row` as their tile but with a small positive bias so they land above the ground and below buildings on the same tile.

## Implementation

### 1. Add a render queue abstraction

Introduce a tiny helper, co-located in `mygame/app/render_queue.rb`:

```ruby
class RenderQueue
  def initialize
    @items = []
  end

  def push(depth:, layer: 0, order: 0, sprite:)
    @items << [depth, layer, order, @items.size, sprite]
  end

  def flush_to(outputs)
    @items.sort_by! { |depth, layer, order, seq, _| [depth, layer, order, seq] }
    @items.each { |_, _, _, _, sprite| outputs.sprites << sprite }
    @items.clear
  end
end
```

Keys, from coarsest to finest:

- `depth` — `col + row` of the anchor tile (plus fractional bias, see below).
- `layer` — fixed per sprite kind to break ties deterministically on the same tile:
  - `0` ground / road
  - `1` road preview
  - `2` building
  - `3` car
- `order` — caller-provided tiebreaker (e.g. `tile_order = row * GRID_SIZE + col`) so ties between different tiles sort consistently.
- `seq` — insertion index, auto-assigned, to preserve stable order for identical keys.

Require the new file from `main.rb` alongside the other requires.

### 2. Own the queue at the frame level

In `main.rb`:

- Instantiate a single `$render_queue = RenderQueue.new` in `initialize_runtime_objects`.
- In `tick`, pass the queue to both renderers:

```ruby
$grid_renderer.enqueue_world(args, $camera, $render_queue)
$car_manager.enqueue_world(args, $camera, $render_queue)
$render_queue.flush_to(args.outputs)
$grid_renderer.render_ui(args)
```

- Keep UI rendering (`render_mode_buttons`, `render_reset_button`) out of the queue so it always draws on top of the world pass.

Do not change the existing public `render` API in a destructive way — introduce `enqueue_world` and `render_ui` on `GridRenderer`, and `enqueue_world` on `CarManager`. `render` on both can be left as a thin wrapper that calls the new methods during the transition, then removed when call sites are updated.

### 3. Ground, roads, and previews

In `GridRenderer#enqueue_world`, replace the direct `args.outputs.sprites <<` calls inside the nested loop with `queue.push(...)`:

- Ground/road sprite:
  - `depth: col + row`
  - `layer: 0`
  - `order: tile_order(col, row)`
- Road preview sprite:
  - `depth: col + row`
  - `layer: 1`
  - `order: tile_order(col, row)`
- Building sprite:
  - `depth: col + row`
  - `layer: 2`
  - `order: tile_order(col, row)`

Keep `draw_tile` as the builder of the sprite hash; just route its output through the queue instead of pushing directly. `tile_order(col, row) = row * GRID_SIZE + col` mirrors the helper already used in `CarManager`.

### 4. Cars

In `CarManager#enqueue_world`, compute the car's anchor tile and its depth:

```ruby
from = path[car[:step_index]]
to   = path[car[:step_index] + 1]
anchor_tile = car[:progress] < CROSSOVER_THRESHOLD ? from : to
depth = anchor_tile[0] + anchor_tile[1]
```

Enqueue with:

- `depth: depth`
- `layer: 3`
- `order: tile_order(anchor_tile[0], anchor_tile[1])`

Rationale:

- A car with `progress < 0.5` is still visually "on" the `from` tile, so sorting against that tile is stable.
- At the crossover threshold, the car swaps to the `to` tile's depth. Since this happens when the car's screen position is at the seam between tiles, the depth change is never visible as a pop.
- Using `col + row` puts the car above the building on the same tile (same `depth`, higher `layer`), and also above any building on a "farther" tile even when they briefly overlap on screen.

Leave `from`/`to` fallback logic unchanged — if `path[step_index + 1]` is missing, reuse `from` as the anchor so the car still renders.

### 5. UI chrome stays out of the queue

Move `render_mode_buttons` and `render_reset_button` into a new `GridRenderer#render_ui` that is called from `main.rb` **after** `flush_to`. This guarantees:

- Buttons never get occluded by a world sprite.
- World sprites never accidentally overdraw the UI because of depth-sort ordering.

No changes to button layout, labels, or state-driven styling — only the call site changes.

### 6. Keep the sort cheap

- Each frame enqueues ~100 ground/road sprites + up to ~100 previews + a handful of buildings + a handful of cars. A single in-place sort over a few hundred entries is well within a tick budget.
- Avoid per-frame allocation spikes: reuse the same `RenderQueue` instance (already wired via `$render_queue`) and clear the buffer in `flush_to` instead of re-instantiating.

### 7. Preserve determinism

The sort key `[depth, layer, order, seq]` is fully deterministic:

- `depth` is tile geometry.
- `layer` is a constant per sprite kind.
- `order` comes from `row * GRID_SIZE + col`.
- `seq` is insertion index.

There is no reliance on iteration order of hashes or on floating-point comparisons, so replays and visual diffs stay stable.

## File Changes

### New files

- `mygame/app/render_queue.rb` — the `RenderQueue` class described in step 1.

### Updated files

- `mygame/app/main.rb`
  - `require 'app/render_queue.rb'`
  - instantiate `$render_queue` in `initialize_runtime_objects`,
  - switch `tick` to `enqueue_world` → `flush_to` → `render_ui`.
- `mygame/app/grid_renderer.rb`
  - add `enqueue_world(args, camera, queue)` replacing the tile-emission body of `render`,
  - add `render_ui(args)` hosting the existing button helpers,
  - route `draw_tile` output through the queue with appropriate `depth` / `layer` / `order`.
- `mygame/app/car_manager.rb`
  - add `enqueue_world(args, camera, queue)` mirroring current `render` but pushing to the queue with the car's tile-based depth,
  - remove the now-unused `render` once `main.rb` no longer calls it (or keep it as a thin wrapper in the interim).

### Files likely unchanged

- `mygame/app/isometric_camera.rb`, `mygame/app/grid_coordinates.rb`, `mygame/app/game_state.rb`, `mygame/app/input_handler.rb`, `mygame/app/pan_controller.rb`, `mygame/app/building_placer.rb`, `mygame/app/road_builder.rb`, `mygame/app/road_graph.rb`, `mygame/app/road_pathfinder.rb` — no depth decisions live in these files.

## Acceptance Criteria

1. A car driving between two buildings is drawn **behind** buildings on tiles with larger `col + row` and **in front of** buildings on tiles with smaller `col + row`.
2. A car on a road tile always draws above the road sprite of the same tile, with no flicker at midpoint crossings.
3. A road preview on any tile draws above that tile's ground and below any building placed on the same tile.
4. UI buttons (mode buttons, reset) always render on top of every world sprite, including cars that pass underneath them.
5. With no buildings or cars on the map, the ground grid looks identical to the current implementation (no visual regression on the baseline scene).
6. Sorting does not introduce per-frame jank: with a full 10×10 grid of tiles plus a handful of buildings and cars, the frame rate is unchanged within noise.

## Validation Steps

1. Place two buildings on a diagonal (e.g. `(2, 2)` and `(6, 6)`), connect with roads, and let the ambulance run the loop. Confirm the car passes **behind** the `(6, 6)` building and **in front of** the `(2, 2)` building.
2. Start a road preview that crosses a tile with an existing building. Confirm the preview draws under the building, not over it.
3. Hover a car sprite path over a mode button's screen footprint (pan the camera so the button overlaps a car tile). Confirm the button stays on top.
4. Drive a car across a midpoint between tiles and visually confirm there is no one-frame pop where the car swaps from drawing under one tile to over another.
5. With the grid empty, compare the ground rendering to a screenshot taken before the change — they should be pixel-identical.
6. Stress test: fill the map with buildings and a few cars; confirm no visible z-order artifacts at the corners or along the near/far diagonals.

## Notes / Decisions

- **Why `col + row` and not screen-space `y`?** Tile geometry is fixed and integer; using `col + row` avoids floating-point comparisons and keeps ties grouped per-tile where `layer` breaks them cleanly. Screen-space `y` would also work but introduces camera-pan-dependent sort keys for no gain.
- **Why a layer enum instead of fractional depth offsets?** Explicit layers are easier to reason about than "add `0.1` for buildings, `0.2` for cars." They also leave room for new sprite kinds (pedestrians, effects) without reshuffling magic numbers.
- **Scope:** this plan intentionally does not touch sprite geometry, camera math, or the car's lane/bias offsets. It only changes the order in which sprites reach `args.outputs.sprites`.
