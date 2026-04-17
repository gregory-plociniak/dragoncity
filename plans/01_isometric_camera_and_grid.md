# Plan: Isometric Camera & Ground Grid

## Goal
Implement an `IsometricCamera` class in `mygame/app/camera.rb` and render a 10×10 isometric grid using `mygame/sprites/ground.png` inside `mygame/app/main.rb`.

---

## Tile Dimensions

`ground.png` is **132×101 px** (RGBA). This is the natural isometric diamond tile.

- `TILE_W = 132`
- `TILE_H = 101`
- Half-values used for offset math: `TILE_W/2 = 66`, `TILE_H/2 = 50` (approx, use integer division)

---

## File Layout

```
mygame/
  app/
    main.rb                  ← require isometric_camera.rb, instantiate Camera, render grid
    isometric_camera.rb   ← IsometricCamera class
  sprites/
    ground.png               ← 132×101 isometric tile
```

---

## Step 1 — `mygame/app/isometric_camera.rb`

Create class `IsometricCamera` with:

```ruby
class IsometricCamera
  attr_accessor :x, :y   # camera world offset (pan)

  def initialize
    @x = 0
    @y = 0
  end

  # Convert isometric grid coordinates (col, row) to screen (x, y).
  # Standard isometric formula:
  #   screen_x = origin_x + (col - row) * (TILE_W / 2)
  #   screen_y = origin_y - (col + row) * (TILE_H / 2)
  # The camera offset (@x, @y) shifts the whole view.
  def world_to_screen(col, row, tile_w, tile_h, origin_x, origin_y)
    sx = origin_x + (col - row) * (tile_w / 2) + @x
    sy = origin_y - (col + row) * (tile_h / 2) + @y
    [sx, sy]
  end
end
```

**Why a class?**  
Encapsulates pan/zoom state so `main.rb` just calls `camera.world_to_screen(...)` without caring about the math.

---

## Step 2 — `mygame/app/main.rb`

### Constants
```ruby
GRID_SIZE  = 10
TILE_W     = 132
TILE_H     = 101
# Isometric origin: roughly center-top of screen so the grid fits
ORIGIN_X   = 640          # horizontal center
ORIGIN_Y   = 600          # high enough to show the full 10×10 grid downward
```

### Bootstrap
```ruby
require 'app/isometric_camera.rb'

$camera = IsometricCamera.new

def tick args
  # black background
  args.outputs.background_color = [0, 0, 0]

  render_grid(args)
  process_inputs(args)
end
```

### Grid rendering
```ruby
def render_grid(args)
  GRID_SIZE.times do |row|
    GRID_SIZE.times do |col|
      sx, sy = $camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
      args.outputs.sprites << {
        x: sx,
        y: sy,
        w: TILE_W,
        h: TILE_H,
        path: 'sprites/ground.png'
      }
    end
  end
end
```

**Render order note:** DragonRuby renders sprites FIFO. Because isometric tiles drawn in `(row=0, col=0) … (row=9, col=9)` order naturally produce correct painter's-algorithm depth (tiles with higher row+col values appear lower on screen and should be drawn last), iterating row-major is correct.

### Camera pan (arrow keys)
```ruby
PAN_SPEED = 4

def process_inputs(args)
  $camera.x += PAN_SPEED  if args.inputs.keyboard.right
  $camera.x -= PAN_SPEED  if args.inputs.keyboard.left
  $camera.y += PAN_SPEED  if args.inputs.keyboard.up
  $camera.y -= PAN_SPEED  if args.inputs.keyboard.down
end
```

---

## Step 3 — Verify layout fits screen

With `ORIGIN_X=640, ORIGIN_Y=600` and a 10×10 grid:

- Leftmost tile `(col=0, row=9)`:  `x = 640 + (0-9)*66 = 640-594 = 46`
- Rightmost tile `(col=9, row=0)`: `x = 640 + (9-0)*66 = 640+594 = 1234`  (+132 = 1366, slightly off right edge — adjust `ORIGIN_X` down to ~580 if needed)
- Top tile `(col=0, row=0)`:       `y = 600 - 0 = 600`
- Bottom tile `(col=9, row=9)`:    `y = 600 - 18*50 = 600-900 = -300` (tile bottom at -300+101 = -199)

The grid is **wider than 1280** at the default origin — after first render, adjust `ORIGIN_X` to `~540` and `ORIGIN_Y` to `~660` to center it, or rely on camera pan. Document this in code comments.

---

## Implementation Order

1. [ ] Create `mygame/app/isometric_camera.rb` with `IsometricCamera` class
2. [ ] Update `mygame/app/main.rb`:
   - Add `require 'app/isometric_camera.rb'`
   - Add constants (`GRID_SIZE`, `TILE_W`, `TILE_H`, `ORIGIN_X`, `ORIGIN_Y`, `PAN_SPEED`)
   - Add `$camera = IsometricCamera.new`
   - Implement `tick` calling `render_grid` and `process_inputs`
   - Implement `render_grid` method
   - Implement `process_inputs` method
3. [ ] Run the game and visually verify the 10×10 ground grid appears
4. [ ] Fine-tune `ORIGIN_X` / `ORIGIN_Y` so the full grid is visible at startup

---

## Notes / Decisions

- **No zoom** in v1 — camera only pans. Zoom can be added later by scaling `TILE_W/H` and the origin offset.
- **Global `$camera`** matches the pattern used in the sample (`$isometric`). Can be refactored to `args.state` later.
- File name `isometric_camera.rb` matches the class name `IsometricCamera` (snake_case ↔ CamelCase convention).
- **Hash-based sprites** are used (not arrays) per DragonRuby best practice for performance.
- The isometric formula assumes **bottom-left origin** (DragonRuby default). `y` increases upward.
