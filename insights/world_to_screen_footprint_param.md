# `world_to_screen` footprint parameter refactor

## Context

Audited `IsometricCamera#world_to_screen` to verify that camera panning moves the view and nothing else.

## Findings

### Panning itself is correct

`@x` and `@y` are added after the isometric projection, so they translate the whole scene uniformly without affecting scale or projection. Sign convention is "world offset" (increasing `@x` shifts world right); acceptable either way as long as it stays consistent.

### Latent bug: `tile_h` parameter was unused

The signature accepted `tile_h` but the y-formula used `tile_w / 4`:

```ruby
sy = origin_y - (col + row) * (tile_w / 4) + @y
```

For a 2:1 iso tile this happens to equal `tile_h / 2` — but only if `tile_h` is the diamond footprint height. In this project `TILE_H = 101` is the full sprite height including elevation pixels above the diamond, so `tile_h / 2 = 50` whereas the correct step is `tile_w / 4 = 33`.

A naïve fix (`tile_w / 4` → `tile_h / 2`) produced stair-stepped ground tiles because it used elevation pixels as if they were footprint.

## Resolution

Renamed the parameter to make the distinction explicit and introduced a project-wide constant:

- `main.rb`: `FOOTPRINT_H = TILE_W / 2` (= 66) — diamond's ground projection height.
- `isometric_camera.rb`: signature is now `(col, row, tile_w, footprint_h, origin_x, origin_y)`, with a comment explaining that `footprint_h != TILE_H`.
- Updated callers in `grid_renderer.rb` and `car_manager.rb` to pass `FOOTPRINT_H`.

## Takeaway

When a sprite embeds visual elevation above its logical footprint, keep the two heights as separate constants. Parameter names like `tile_h` invite the wrong value — `footprint_h` forces the caller to think about which dimension the math actually needs.
