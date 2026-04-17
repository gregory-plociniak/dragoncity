# Plan: Mouse Drag Panning

## Goal

Allow the player to pan the isometric camera by clicking and dragging anywhere on screen with the left mouse button.

## Relevant API

From `docs/api/inputs.md`:

- `args.inputs.mouse.button_left` — `true` while left button is held down
- `args.inputs.mouse.relative_x` — horizontal delta (pixels) since last frame
- `args.inputs.mouse.relative_y` — vertical delta (pixels) since last frame
- `args.inputs.mouse.moved` — `true` if mouse moved this frame (guard against jitter on click)

## Implementation Steps

### 1. Add drag handling to `process_inputs` in `mygame/app/main.rb`

Inside `process_inputs(args)`, add a block that fires when the left mouse button is held **and** the mouse has moved:

```ruby
if args.inputs.mouse.button_left && args.inputs.mouse.moved
  $camera.x -= args.inputs.mouse.relative_x
  $camera.y -= args.inputs.mouse.relative_y
end
```

- Subtract `relative_x`/`relative_y` because dragging right should move the world right (camera origin goes left), matching the feel of "grabbing" the map.
- No new state or class changes needed — `IsometricCamera` already exposes `x` and `y`.

### 2. Keep keyboard panning

Arrow-key panning in `process_inputs` stays unchanged so both input methods coexist.

### 3. Optional: cursor feedback

To signal drag mode visually, set a custom cursor or render a "grab" indicator when `args.inputs.mouse.button_left` is true. This is cosmetic and can be added later.

## Files to Change

| File | Change |
|------|--------|
| `mygame/app/main.rb` | Add 3-line mouse drag block inside `process_inputs` |

## No Changes Needed

- `mygame/app/isometric_camera.rb` — `x`/`y` are already mutable; no new methods required.
- Constants (`TILE_W`, `TILE_H`, `ORIGIN_X`, `ORIGIN_Y`) — untouched.

## Expected Result

- Click and hold anywhere → cursor "grabs" the map.
- Drag mouse → camera pans smoothly at 1:1 pixel ratio.
- Release → panning stops.
- Arrow keys continue to work in parallel.
