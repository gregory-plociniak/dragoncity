# Plan: Transparent Road Preview While Drawing

## Goal

When the player is in **roads mode** and drags with the left mouse button, the road stroke should be visible immediately as a **partly transparent preview** before it is committed. The preview should follow the current drag path tile-by-tile, use the same road sprites as the final placement, and become fully opaque only after the drag finishes.

This is a behavior change from the current implementation in [mygame/app/input_handler.rb](/Users/gregory/dragoncity/mygame/app/input_handler.rb), which writes road tiles directly into `args.state.roads` during the drag.

---

## Current behavior

`handle_road_input` currently:

1. Starts a drag on `mouse.key_down.left`.
2. Converts the current mouse position to a grid tile while `mouse.button_left` is true.
3. Applies road segments directly to `args.state.roads` as the cursor crosses tiles.
4. Clears drag bookkeeping on `mouse.key_up.left`.

Because placement is committed immediately, there is no separate visual state for “road being drawn right now”. Any preview rendered on top would either be redundant or would require dimming already-committed roads.

---

## Proposed approach

Introduce a separate **road preview layer** on `args.state` and only merge it into `args.state.roads` when the drag ends.

### Persistent state

Keep the existing committed map:

```ruby
args.state.roads ||= {}   # committed roads
```

Add preview-only drag state:

```ruby
args.state.road_preview      ||= {}   # "col,row" => :ne | :nw | :cross
args.state.road_drag_last    ||= nil
args.state.road_drag_kind    ||= nil
args.state.road_drag_origin  ||= nil  # optional, useful if later we need restart logic
```

`road_preview` should exist only for the active stroke. It should be cleared when:

- the player enters or leaves road mode
- a drag starts
- a drag ends
- a drag is cancelled or leaves valid placement flow

---

## Input flow changes

Refactor `handle_road_input` so it builds preview state during drag and commits only on release.

### Drag start

On `mouse.key_down.left`:

1. Clear any previous preview state.
2. Reset `road_drag_last` and `road_drag_kind`.
3. Optionally capture the first valid tile as the stroke start once the cursor is inside bounds.

### Drag update

While `mouse.button_left` is true:

1. Convert mouse coordinates to `[col, row]`.
2. Ignore samples outside the grid.
3. If this is the first valid tile in the stroke, store it as `road_drag_last`.
4. If the tile has not changed, do nothing.
5. If the tile changed:
   - derive `road_kind` from the delta
   - preserve the current straight-line constraint using `road_drag_kind`
   - walk each straight step between the previous tile and the current tile
   - write the segment result into `args.state.road_preview` instead of `args.state.roads`
6. Update `road_drag_last` to the current tile after accepting the step.

### Drag end

On `mouse.key_up.left`:

1. Merge `args.state.road_preview` into `args.state.roads`.
2. Clear `road_preview`, `road_drag_last`, and `road_drag_kind`.

This preserves the current placement rules while making the active stroke renderable as a distinct semi-transparent layer.

---

## Merge rules

Reuse the existing road merge logic for both preview construction and final commit:

```ruby
def merge_road(existing, incoming)
  return incoming unless existing
  return existing if existing == incoming
  :cross
end
```

Two merge points are needed:

1. **Within preview**
   When a drag revisits a preview tile with the opposite direction, upgrade that preview tile to `:cross`.

2. **Preview into committed roads**
   On mouse release, merge each preview tile into the existing committed road map so crossings still upgrade correctly when a new stroke overlaps an older road.

Add a small helper for commit:

```ruby
def commit_road_preview(state)
  state.road_preview.each do |key, road_kind|
    state.roads[key] = merge_road(state.roads[key], road_kind)
  end
end
```

---

## Rendering changes

Update [mygame/app/grid_renderer.rb](/Users/gregory/dragoncity/mygame/app/grid_renderer.rb) to render both committed roads and preview roads.

### Layer order per tile

The tile-local render order should become:

1. ground
2. committed road, if present
3. preview road, if present, with partial alpha
4. building, if present

That keeps the preview visible over the terrain and existing road base while still letting buildings remain the top-most tile content.

### Preview alpha

Render preview sprites using the same path lookup as committed roads, but include an alpha value such as:

```ruby
a: 128
```

`128` is a reasonable starting point because it is clearly visible while still distinct from committed roads. If the sprite reads too faintly over ground, adjust upward to something in the `160..200` range.

### Sprite selection

Reuse `road_sprite_path` for both layers so preview and final placement always match:

```ruby
preview_kind = args.state.road_preview["#{col},#{row}"]
preview_path = road_sprite_path(preview_kind)
```

---

## File changes

### `mygame/app/main.rb`

- Initialize `args.state.road_preview ||= {}`.
- Keep the existing road drag fields or rename them only if the refactor makes that cleaner.

### `mygame/app/input_handler.rb`

- Stop calling `apply_road(args.state.roads, ...)` during active drag.
- Add preview writes via `apply_road(args.state.road_preview, ...)`.
- Add a commit step on `mouse.key_up.left`.
- Clear preview state when toggling out of roads mode.
- Keep the existing straight-line and bounds logic unless the feature scope intentionally expands.

### `mygame/app/grid_renderer.rb`

- Split road rendering into committed and preview layers.
- Draw preview sprites with partial transparency.
- Keep buildings rendering after both road layers.

---

## Suggested helpers

To keep `handle_road_input` readable, extract the preview lifecycle into small private helpers:

- `clear_road_preview(state)`
- `commit_road_preview(state)`
- `apply_preview_road(preview, col, row, road_kind)`
- `road_key(col, row)` or reuse `tile_key`

This keeps input flow focused on mouse state transitions instead of mixing placement, commit, and cleanup details into one method.

---

## Acceptance criteria

1. In `:roads` mode, dragging across valid tiles shows road sprites immediately under the cursor path.
2. The active drag path is visibly semi-transparent and distinct from committed roads.
3. Releasing the left mouse button converts the previewed tiles into normal opaque roads.
4. Existing roads remain persisted in `args.state.roads`; temporary drag data does not survive after release.
5. Crossing or overlapping a committed road still upgrades the affected tile to `:cross` when appropriate.
6. Leaving roads mode clears any unfinished preview so no transparent roads remain on screen.
7. Buildings still render above both committed and preview road layers.

---

## Verification checklist

1. Enter roads mode with `R`.
2. Click and drag horizontally across several tiles: preview should use `road_NE.png` with partial alpha.
3. Release the mouse: the same tiles should remain, now fully opaque.
4. Repeat vertically: preview should use `road_NW.png`.
5. Draw a new stroke across an existing road: the intersection should resolve to `crossroad.png` after release.
6. Start a drag, then toggle out of road mode before finishing: preview should disappear and no partial placement should remain.
