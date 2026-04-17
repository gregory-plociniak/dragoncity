# Plan: Refactor `InputHandler` into Focused Collaborators

## Goal

Break [`mygame/app/input_handler.rb`](/Users/gregory/dragoncity/mygame/app/input_handler.rb) into smaller, single-responsibility pieces so each concern (mode dispatch, UI hit-testing, panning, building placement, road drawing, grid geometry) lives with code that only cares about that concern. Also lift some state-initialization boilerplate out of [`mygame/app/main.rb`](/Users/gregory/dragoncity/mygame/app/main.rb) so `tick` reads as a short orchestration layer.

The refactor should be **behavior-preserving**: no gameplay changes, no new features. Only structure changes.

---

## Current situation

`InputHandler` has grown to ~200 lines and mixes eight concerns:

1. **Mode dispatch** — `process`, `change_mode`
2. **UI click routing** — `handle_ui_click` (reset button + mode buttons)
3. **Camera panning** — `handle_pan_input`
4. **Building placement rules** — `handle_build_input`, `road_nearby?`
5. **Invalid-build feedback lifecycle** — `flash_invalid_build_tile`, `prune_expired_build_feedback`
6. **Road drawing state machine** — `handle_road_input`, `clear_road_preview`, `commit_road_preview`
7. **Road geometry** — `each_straight_step`, `delta_to_road_kind`, `apply_road`, `apply_preview_road`, `merge_road`
8. **Grid coordinate helpers** — `screen_to_grid`, `in_bounds?`, `tile_key`

Cross-file smells:

- `tile_key` logic is duplicated inline in [`grid_renderer.rb`](/Users/gregory/dragoncity/mygame/app/grid_renderer.rb) (`"#{col},#{row}"`).
- `tick` in [`main.rb`](/Users/gregory/dragoncity/mygame/app/main.rb) does eight `||=` state initializations inline — noisy and easy to forget when adding new state.
- Constants (`GRID_SIZE`, `TILE_W`, `ORIGIN_X`, `ORIGIN_Y`, `PAN_SPEED`, `BUILD_INVALID_FLASH_FRAMES`, …) are top-level globals, fine for DragonRuby but worth grouping as the app grows.

---

## Proposed structure

```
mygame/app/
  main.rb                   # orchestration + constants + reset hook
  isometric_camera.rb       # unchanged
  grid_renderer.rb          # unchanged externally, uses GridCoordinates helper
  grid_coordinates.rb       # NEW  — pure geometry helpers
  input_handler.rb          # SHRUNK — mode dispatch + UI click routing only
  pan_controller.rb         # NEW  — keyboard + mouse-drag camera panning
  building_placer.rb        # NEW  — build input + road-proximity rule + invalid-flash feedback
  road_builder.rb           # NEW  — road drag state machine + preview/commit + road merge rules
  game_state.rb             # NEW  — one-shot args.state initialization
```

Each new file is small (roughly 20–60 lines). No new third-party dependencies.

---

## New class responsibilities

### `GridCoordinates` (module)

Pure functions. No instance state, no `args`.

- `screen_to_grid(mx, my, camera)` → `[col, row]`
- `in_bounds?(col, row)` → Boolean
- `tile_key(col, row)` → `"col,row"` string

Consumed by `InputHandler`, `RoadBuilder`, `BuildingPlacer`, and `GridRenderer` (replacing the inline `"#{col},#{row}"` there).

**Why a module, not a class:** these are stateless helpers and all three callers currently duplicate or re-derive them.

### `PanController`

Owns `handle_pan_input(args, camera)` verbatim. Trivial class, but isolates keyboard/mouse-drag camera movement from mode-agnostic routing.

### `BuildingPlacer`

Owns everything tied to `:build` mode and the invalid-tile flash:

- `handle_click(args, camera)` — current `handle_build_input`
- `road_nearby?(roads, col, row)` — building placement rule
- `flash_invalid(state, key)` — current `flash_invalid_build_tile`
- `prune_expired(state)` — current `prune_expired_build_feedback`

`prune_expired` is called once per tick; the caller (main.rb or InputHandler) invokes it before mode dispatch.

### `RoadBuilder`

Owns the drag state machine for `:roads` mode:

- `handle_input(args, camera)` — current `handle_road_input`
- `clear_preview(state)` — current `clear_road_preview`
- `commit_preview(state)` — current `commit_road_preview`

Plus the pure road-geometry helpers used only here:

- `each_straight_step`, `delta_to_road_kind`, `apply_road`, `apply_preview_road`, `merge_road`

`InputHandler` calls `road_builder.clear_preview(state)` when the user switches modes, which is the one cross-call into this class.

### `GameState`

One method:

```ruby
module GameState
  def self.initialize!(state)
    state.mode           ||= :pan
    state.buildings      ||= {}
    state.roads          ||= {}
    state.road_preview   ||= {}
    state.road_drag_last ||= nil
    state.road_drag_kind ||= nil
    state.invalid_build_tiles ||= {}
    state.frame_index    ||= 0
    state.mode_buttons   ||= {
      pan:   Layout.rect(row: 0, col: 0, w: 3, h: 1),
      build: Layout.rect(row: 0, col: 3, w: 3, h: 1),
      roads: Layout.rect(row: 0, col: 6, w: 3, h: 1)
    }
    state.reset_button   ||= Layout.rect(row: 0, col: 21, w: 3, h: 1)
  end
end
```

`tick` becomes a one-line `GameState.initialize!(args.state)` plus `state.frame_index += 1`.

### `InputHandler` (shrunk)

After the split, `InputHandler` only owns:

- `process(args, camera)` — calls `BuildingPlacer#prune_expired`, then `handle_ui_click`, then dispatches to `PanController`, `BuildingPlacer`, or `RoadBuilder` by mode.
- `handle_ui_click(args)` — reset-button + mode-button hit-testing.
- `change_mode(args, new_mode)` — still needs to call `@road_builder.clear_preview(args.state)` so switching away from `:roads` discards an in-progress drag.

Collaborators are injected once in the constructor:

```ruby
def initialize
  @pan        = PanController.new
  @building   = BuildingPlacer.new
  @roads      = RoadBuilder.new
end
```

---

## What stays in `main.rb`

- Constants (`GRID_SIZE`, `TILE_W`, `ORIGIN_*`, `PAN_SPEED`, `BUILD_INVALID_FLASH_FRAMES`, building tile offsets).
- `require` lines for each new file.
- `initialize_runtime_objects` / `reset args` hook — unchanged in spirit.
- `tick` — shrunk to:
  ```ruby
  def tick args
    GameState.initialize!(args.state)
    args.state.frame_index += 1

    args.outputs.background_color = [0, 0, 0]
    $grid_renderer.render(args, $camera)
    $input_handler.process(args, $camera)
  end
  ```

Constants are intentionally **not** moved. They are small, already well-named, and used across files; a `GameConfig` module would be premature.

---

## What does NOT need a new class

- **Mode dispatch** — the `case args.state.mode` block in `process` is five lines; extracting a `ModeDispatcher` would just add indirection.
- **UI click routing** — two buttons + a `.each` loop. Fine where it is. Revisit only if a third UI surface appears.
- **Reset hook** — already lives in `main.rb`; leave it.

---

## Migration order

Each step is independently runnable; commit between steps.

1. **Extract `GridCoordinates`.** Add `mygame/app/grid_coordinates.rb`, require it in `main.rb`, replace call sites in `InputHandler` and the inline `"#{col},#{row}"` in `GridRenderer`. Verify render + all three modes still work.
2. **Extract `GameState`.** Move the eight `||=` lines out of `tick` into `GameState.initialize!`. `frame_index += 1` stays in `tick`.
3. **Extract `PanController`.** Move `handle_pan_input` verbatim. Inject into `InputHandler`.
4. **Extract `BuildingPlacer`.** Move `handle_build_input`, `road_nearby?`, `flash_invalid_build_tile`, `prune_expired_build_feedback`. `InputHandler#process` now calls `@building.prune_expired(args.state)` at the top instead of `prune_expired_build_feedback`.
5. **Extract `RoadBuilder`.** Move road-mode handling and all road-geometry helpers. `change_mode` now delegates preview-clearing to the road builder.
6. **Final pass on `InputHandler`.** File should be ~40 lines: `process`, `handle_ui_click`, `change_mode`, and the collaborator wiring.

Each step is a pure move-and-rename; no logic changes.

---

## Edge cases to preserve

1. **Mode switch mid-drag.** `change_mode` must still call `RoadBuilder#clear_preview` so leaving `:roads` while dragging discards the preview and drag-last/drag-kind state. Currently handled by `clear_road_preview(args.state)` in `change_mode`.
2. **Reset button during a road drag.** `handle_ui_click` returns `true` before mode-specific handlers run, so the drag simply stops and `GTK.reset_next_tick` wipes state. Unchanged by this refactor.
3. **Invalid-build flash decay.** `prune_expired` must run every tick, not just on click, or stale red tiles will persist. The current code calls it unconditionally at the top of `process`; keep that.
4. **`tile_key` string format.** `GridRenderer` and `InputHandler` both use `"col,row"`. Routing everything through `GridCoordinates.tile_key` removes the duplication; do not change the format or existing saved state will key-mismatch.
5. **`screen_to_grid` coordinate math.** The isometric inversion is subtle (see previous camera/grid fixes). Copy the body verbatim; do not "clean up" the floor/divide order.

---

## Acceptance criteria

1. `mygame/app/input_handler.rb` is ≤ ~50 lines and only handles mode dispatch + UI clicks.
2. New files `grid_coordinates.rb`, `pan_controller.rb`, `building_placer.rb`, `road_builder.rb`, `game_state.rb` exist and are required from `main.rb`.
3. `tick` in `main.rb` no longer contains inline `args.state.X ||= …` initializers except `frame_index`.
4. `GridRenderer` uses `GridCoordinates.tile_key` instead of inline interpolation.
5. All existing gameplay works identically: pan (keyboard + drag), build placement with road-adjacency rule + invalid flash, road drag with preview + commit + merge-to-crossroad, UI buttons (pan/build/roads/reset), reset hook.

---

## Verification checklist

1. Launch the game — grid renders, default mode is `:pan`.
2. Pan with arrow keys and mouse drag — camera moves.
3. Click `BUILD` — mode switches; click on a grid tile adjacent to a road → building appears. Click a non-adjacent tile → red flash, no building, flash fades after ~20 frames.
4. Click a placed building → it is removed.
5. Click `ROADS` — mode switches; click-drag along a row → straight road preview appears semi-transparent; release → roads commit.
6. Drag across an existing road of the opposite kind → merges to `:cross`.
7. Start a road drag, then click a mode button mid-drag → preview clears, drag state resets, no orphaned `road_drag_last`/`road_drag_kind`.
8. Click `RESET` → grid returns to centered view, all buildings/roads/previews gone, mode back to `:pan`.
9. `grep` for `"#{col},#{row}"` across `mygame/app/` — should only appear inside `GridCoordinates.tile_key`.
10. `wc -l mygame/app/input_handler.rb` — noticeably smaller than the pre-refactor ~200 lines.
