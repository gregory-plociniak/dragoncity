# Plan: Road Placement Mode

## Goal

Extend the current mode system so building placement stays available and roads are added as a separate placement mode. In **pan mode** (default) the camera keeps its current keyboard + mouse drag behavior. In **build mode** the existing left-click building placement continues to work. In **roads mode** the left mouse button is used to drag across ground tiles and lay road sprites on the grid instead of panning the camera.

The dragged road uses the existing sprites:

| Sprite | Meaning |
|---|---|
| `sprites/road_NE.png` | segment running along the screen's southwest ↔ northeast diagonal |
| `sprites/road_NW.png` | segment running along the screen's southeast ↔ northwest diagonal |
| `sprites/crossroad.png` | optional upgrade when one tile contains both segment directions |

All three sprites are already `132 × 101`, so they can render with the same footprint as `ground.png`.

---

## Mode toggle

Keep **`B`** for building placement and add **`R`** for road placement.

```ruby
if args.inputs.keyboard.key_down.b
  args.state.mode = (args.state.mode == :build) ? :pan : :build
end

if args.inputs.keyboard.key_down.r
  args.state.mode = (args.state.mode == :roads) ? :pan : :roads
end
```

Initialize the mode once in `tick`:

```ruby
args.state.mode ||= :pan
```

Update the HUD label to show `Mode: PAN`, `Mode: BUILD`, or `Mode: ROADS`.

---

## Road state

Keep the existing building set and add a separate road map on `args.state`:

```ruby
args.state.buildings ||= {}  # existing building placement state
args.state.roads ||= {}   # "col,row" => :ne | :nw | :cross
```

Track the active drag stroke separately:

```ruby
args.state.road_drag_last ||= nil   # [col, row] from the previous sampled tile
```

Using `args.state` keeps the placed roads alive through hot reload.

---

## Screen → grid conversion

Reuse the same `screen_to_grid` math already used by `InputHandler`. The inverse of `IsometricCamera#world_to_screen` stays:

```ruby
def screen_to_grid(mx, my, tile_w, origin_x, origin_y, camera)
  dx =  (mx - origin_x - camera.x).to_f
  dy = -(my - origin_y - camera.y).to_f

  u = dx / (tile_w / 2.0)
  v = dy / (tile_w / 4.0)

  col = ((u + v) / 2.0).floor
  row = ((v - u) / 2.0).floor
  [col, row]
end
```

Only use results where `col` and `row` are both within `0...GRID_SIZE`.

---

## Drag placement flow

Use the mouse button state from `args.inputs.mouse` rather than `mouse.click`, because road placement is a continuous stroke:

1. On `args.inputs.mouse.key_down.left`, clear `args.state.road_drag_last`.
2. While `args.state.mode == :roads` and `args.inputs.mouse.button_left` is true:
   - Convert the current mouse position to `[col, row]`.
   - Ignore samples outside the grid.
   - If this is the first valid tile in the stroke, store it in `road_drag_last` and wait for the next tile.
   - If the tile is unchanged, do nothing.
   - If the tile changed, compare it to `road_drag_last` and place a road segment for each orthogonally adjacent step between them.
3. On `args.inputs.mouse.key_up.left`, clear `args.state.road_drag_last`.

The segment kind comes from the grid delta:

```ruby
delta_col = current_col - previous_col
delta_row = current_row - previous_row

if delta_row == 0
  road_kind = :ne   # walking across columns draws the SW ↔ NE sprite
elsif delta_col == 0
  road_kind = :nw   # walking across rows draws the SE ↔ NW sprite
else
  road_kind = nil   # ignore diagonal jumps for now
end
```

For each accepted step, apply the segment to both the previous tile and the current tile so the stroke remains continuous from end to end.

---

## Merging road kinds

Dragging a straight line only needs `:ne` or `:nw`, but a turn or a later crossing can revisit a tile with the opposite direction. Add a small helper to merge kinds:

```ruby
def merge_road(existing, incoming)
  return incoming unless existing
  return existing if existing == incoming
  :cross
end
```

This lets a tile upgrade from `:ne` or `:nw` to `:cross`, which maps cleanly to the existing `sprites/crossroad.png`.

If you want to keep the first implementation narrower, you can ship phase 1 without turns/crossroads and add this helper immediately after straight dragging works.

---

## Rendering

Update `GridRenderer` to draw roads inline with the ground tiles, while keeping the current building rendering:

```ruby
road = args.state.roads["#{col},#{row}"]
path =
  case road
  when :ne    then 'sprites/road_NE.png'
  when :nw    then 'sprites/road_NW.png'
  when :cross then 'sprites/crossroad.png'
  end

args.outputs.sprites << {
  x: sx - TILE_W / 2,
  y: sy - TILE_H,
  w: TILE_W,
  h: TILE_H,
  path: path
} if path
```

The render order on each tile should become:

1. ground
2. road, if present
3. building, if present

Roads should draw immediately after the ground tile, and buildings should remain the top-most tile-local layer so they visually sit on top of the road.

---

## File changes

### `mygame/app/main.rb`
- Keep `args.state.buildings ||= {}`.
- Add `args.state.roads ||= {}`.
- Keep `args.state.mode ||= :pan`.

### `mygame/app/input_handler.rb`
- Keep the existing `B` toggle for `:build`.
- Add an `R` toggle for `:roads`.
- Keep pan behavior unchanged while `args.state.mode == :pan`.
- In `:build` mode, keep the current click-to-toggle building behavior.
- In `:roads` mode, use drag placement instead of `args.inputs.mouse.click`.
- Add stroke tracking with `mouse.key_down.left`, `mouse.button_left`, and `mouse.key_up.left`.
- Reuse `screen_to_grid`.
- Add helpers for:
  - bounds checking
  - interpolating straight tile-to-tile steps during a drag
  - converting a delta into `:ne` or `:nw`
  - merging an incoming road with the tile's existing kind

### `mygame/app/grid_renderer.rb`
- Keep building sprite rendering.
- Add road sprite rendering before the building sprite on each tile.
- Update the HUD label text to include both mode shortcuts, for example:

```ruby
"Mode: #{args.state.mode.upcase}  [B] build  [R] roads"
```

---

## Acceptance criteria

1. Default mode is still pan, and existing camera movement is unchanged there.
2. Pressing `B` switches between `:pan` and `:build`; pressing `R` switches between `:pan` and `:roads`.
3. In build mode, clicking a ground tile still places or removes a building exactly as it does today.
4. In roads mode, holding the left mouse button and dragging across adjacent tiles lays road segments continuously.
5. Horizontal grid movement uses `sprites/road_NE.png`; vertical grid movement uses `sprites/road_NW.png`.
6. Mouse drag in roads mode does not pan the camera.
7. Roads render underneath buildings on the same tile.
8. Re-visiting a tile with the opposite road direction upgrades it to `sprites/crossroad.png`, or is explicitly deferred as a phase-2 item.
9. Buildings and roads both persist through hot reload because they live on `args.state`.
