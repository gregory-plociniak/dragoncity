# Isometric Tile Geometry

## Sprite structure (`sprites/ground.png`)

The ground tile is a 132×101px isometric block with two visual zones:
- **Top diamond face:** 132px wide, 66px tall (`TILE_W / 2` — standard 2:1 isometric ratio)
- **Side walls:** remaining ~35px below the diamond

## Correct sprite placement

`world_to_screen` returns `(sx, sy)` — the screen position of the diamond's top vertex.

```ruby
x: sx - TILE_W / 2   # center sprite horizontally on top vertex
y: sy - TILE_H        # align sprite bottom so top vertex lands at sy
```

## Correct vertical step formula

Each grid step (col or row ±1) shifts the top vertex by:
- Horizontal: `TILE_W / 2 = 66px`
- Vertical: half the diamond face height = `(TILE_W / 2) / 2 = TILE_W / 4 = 33px`

```ruby
sy = origin_y - (col + row) * (tile_w / 4) + @y  # correct
# NOT tile_h / 2 = 50 — that includes side walls, not just the diamond face
```

## Why `tile_h / 2` was wrong

`TILE_H = 101` is the full sprite height including side walls. Using it for the vertical step overstated the drop per tile (50px instead of 33px), making each tile appear as a stair step rather than interlocking with its neighbor into a flat surface.

## Bugs fixed

1. `x: sx - TILE_W` → `x: sx - TILE_W / 2` — sprite was offset a full tile width left instead of half
2. Vertical step `tile_h / 2` → `tile_w / 4` — was using full sprite height instead of diamond-face height
