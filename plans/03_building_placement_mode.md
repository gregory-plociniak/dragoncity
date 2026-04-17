# Plan: Building Placement Mode

## Goal

Add a `build` mode toggle. In **pan mode** (default) the mouse drag and arrow keys pan the camera as today. In **build mode** left-clicking a ground tile places `sprites/building1.png` on that tile; dragging no longer pans.

---

## Sprite reference

| Sprite | Size |
|---|---|
| `sprites/ground.png` | 132 × 101 px |
| `sprites/building1.png` | 132 × 101 px (isometric block, same footprint) |

---

## Mode toggle

Press **`B`** on the keyboard to flip between `:pan` and `:build`.  
Display the current mode in the top-left corner via `args.outputs.labels`.

```ruby
# InputHandler reads:
if args.inputs.keyboard.key_down.b
  args.state.mode = (args.state.mode == :build) ? :pan : :build
end
```

`args.state.mode` is initialized to `:pan` on the first tick via `||=`.

---

## Building state

Store placed buildings as a `Set` (or `Hash` acting as a set) of `[col, row]` pairs on `args.state`:

```ruby
args.state.buildings ||= {}   # key: "col,row" string  →  value: true
```

Using `args.state` means the data survives hot-reload automatically.

---

## Screen → grid coordinate conversion

The inverse of `IsometricCamera#world_to_screen`:

```
sx = origin_x + (col - row) * (tile_w / 2) + camera.x
sy = origin_y - (col + row) * (tile_w / 4) + camera.y
```

Solving for `col` and `row`:

```ruby
def screen_to_grid(mx, my, tile_w, origin_x, origin_y, camera)
  dx =  (mx - origin_x - camera.x).to_f
  dy = -(my - origin_y - camera.y).to_f   # flip: DragonRuby y is bottom-up

  # col - row  =  dx / (tile_w / 2)
  # col + row  = -dy / (tile_w / 4)   ( dy is negative going up on screen )
  u = dx / (tile_w / 2.0)
  v = dy / (tile_w / 4.0)

  col = ((u + v) / 2.0).floor
  row = ((v - u) / 2.0).floor
  [col, row]
end
```

Only accept the result when `col` and `row` are both in `0...GRID_SIZE`.

---

## Hit detection refinement (optional, phase 2)

The formula above uses the bounding rectangle. For accurate diamond-only hit detection, after computing `col`/`row`, compute the tile's `sx`/`sy` back from the camera, then test if the mouse is inside the diamond polygon (4 vertices). Skip for now; rectangle hit is good enough for a 10×10 grid.

---

## Render order (painter's algorithm)

The grid is already rendered back-to-front (row 0 col 0 → row N col N). Buildings must be drawn **immediately after** their ground tile in the same loop so depth is correct:

```ruby
GRID_SIZE.times do |row|
  GRID_SIZE.times do |col|
    sx, sy = camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)

    # ground tile
    args.outputs.sprites << { x: sx - TILE_W / 2, y: sy - TILE_H,
                               w: TILE_W, h: TILE_H, path: 'sprites/ground.png' }

    # building on this tile (if any)
    if args.state.buildings["#{col},#{row}"]
      args.outputs.sprites << { x: sx - TILE_W / 2, y: sy - TILE_H,
                                 w: TILE_W, h: TILE_H, path: 'sprites/building1.png' }
    end
  end
end
```

---

## File changes

### `mygame/app/main.rb`
- Initialize `args.state.mode ||= :pan` in `tick`.
- Pass `args.state` to `InputHandler#process` and `GridRenderer#render`.

### `mygame/app/input_handler.rb`
- Read `args.state.mode`.
- **Pan mode:** existing camera pan logic (keyboard + mouse drag), unchanged.
- **Build mode:** on `args.inputs.mouse.click` (single click, not drag):
  - Call `screen_to_grid` with the click's `x`/`y`.
  - If within grid bounds, toggle `args.state.buildings["col,row"]` (click again to remove).
  - No camera movement.
- **Always:** handle `key_down.b` to toggle mode.
- Add `screen_to_grid` as a private method here (it only needs `TILE_W`, `ORIGIN_X`, `ORIGIN_Y`, and the camera).

### `mygame/app/grid_renderer.rb`
- Accept `args.state.buildings` and render building sprites inline as shown above.
- Add HUD label showing current mode.

---

## Acceptance criteria

1. Default mode is pan; existing pan behavior is unchanged.
2. Pressing `B` switches to build mode; HUD label updates.
3. In build mode, clicking a ground tile places `building1.png`; clicking again removes it.
4. Mouse drag in build mode does **not** pan the camera.
5. Buildings render with correct isometric depth (never appear in front of tiles that should overlap them).
6. State survives hot-reload (no buildings lost on code save).
