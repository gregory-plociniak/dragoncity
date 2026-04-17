# Plan: Reset Button on the Right Side of the Layout

## Goal

Add a **RESET** button to the top UI bar, positioned on the far right side of the safe-area layout and styled consistently with the existing **PAN**, **BUILD**, and **ROADS** buttons.

Clicking **RESET** should restart the game state cleanly: clear buildings, roads, previews, mode state, and camera offset so the game returns to its initial view.

---

## Current behavior

The current UI already renders three mode buttons via `Layout.rect`:

- `pan` at `col: 0`
- `build` at `col: 3`
- `roads` at `col: 6`

These are initialized in [mygame/app/main.rb](/Users/gregory/dragoncity/mygame/app/main.rb), rendered in [mygame/app/grid_renderer.rb](/Users/gregory/dragoncity/mygame/app/grid_renderer.rb), and hit-tested in [mygame/app/input_handler.rb](/Users/gregory/dragoncity/mygame/app/input_handler.rb).

There is no reset UI yet. The game state lives mostly in `args.state`, but the camera is stored in the global `$camera`, so resetting only `args.state` would not fully restore the initial game view.

---

## Proposed approach

Introduce a dedicated `reset_button` rect using `Layout.rect(row: 0, col: 21, w: 3, h: 1)` so it occupies the last three columns of the 24-column landscape layout. This places it on the very right edge of the same top row used by the mode buttons.

Keep the reset button visually identical to the other controls:

- same height and width
- same filled-button rendering
- same centered label treatment
- its own label text: `RESET`

Unlike the mode buttons, **RESET** is an action button, not a persistent mode, so it should not receive the “active” highlight state.

---

## Reset behavior

Use `GTK.reset_next_tick` when the reset button is clicked.

This is preferable to `GTK.reset` because the click is handled during `tick`, and `reset_next_tick` avoids wiping state mid-frame.

Because DragonRuby does **not** reset global objects automatically, add a top-level `reset args` hook in [mygame/app/main.rb](/Users/gregory/dragoncity/mygame/app/main.rb) that recreates:

- `$camera`
- `$grid_renderer`
- `$input_handler`

That ensures the camera offset returns to `(0, 0)` after reset rather than preserving the user’s last panned position.

---

## Input flow changes

Extend the existing `handle_ui_click(args)` flow in [mygame/app/input_handler.rb](/Users/gregory/dragoncity/mygame/app/input_handler.rb) to recognize the reset button before mode-specific input runs.

### Button hit-testing order

1. If the mouse click intersects the reset button, call `GTK.reset_next_tick` and return `true`.
2. Otherwise, check the mode buttons as today.
3. If no UI element was hit, return `false` so normal game interaction proceeds.

This preserves the current protection against accidentally placing a building or drawing a road underneath a UI control.

### Suggested structure

The simplest change is to keep separate state entries:

- `args.state.mode_buttons`
- `args.state.reset_button`

Then update `handle_ui_click` to test `reset_button` first, followed by iterating `mode_buttons`.

If desired, a small helper can centralize UI button hit-testing, but the feature is simple enough that a dedicated `reset_button` branch is sufficient.

---

## Rendering changes

Add reset-button rendering alongside the existing `render_mode_buttons(args)` logic in [mygame/app/grid_renderer.rb](/Users/gregory/dragoncity/mygame/app/grid_renderer.rb).

Two reasonable options:

1. Keep `render_mode_buttons(args)` and add a sibling `render_reset_button(args)`.
2. Generalize into a single top-bar renderer that draws mode buttons plus the reset action.

Preferred: keep the current mode-button method and add `render_reset_button(args)` for the smallest change.

### Reset button visuals

- Reuse the same solid-rectangle button style.
- Use a neutral inactive palette matching the non-active mode buttons, or a slightly warmer accent to signal a destructive/reset action.
- Center the `RESET` label with `rect.center.merge(anchor_x: 0.5, anchor_y: 0.5)`.

If a distinct color is used, keep it restrained so it still feels like part of the same control strip.

---

## File changes

### `mygame/app/main.rb`

- Add `args.state.reset_button ||= Layout.rect(row: 0, col: 21, w: 3, h: 1)`.
- Add a top-level `reset args` method that reinstantiates the global objects.

### `mygame/app/input_handler.rb`

- Update `handle_ui_click(args)` to check `args.state.reset_button`.
- On reset-button click, call `GTK.reset_next_tick` and return `true`.
- Leave mode-button handling in place after the reset-button branch.

### `mygame/app/grid_renderer.rb`

- Add rendering for the reset button.
- Call the reset-button renderer from `render(args, camera)` after or alongside the existing mode-button renderer.

---

## Edge cases

1. **Clicking RESET while dragging a road**
   The UI click should be consumed before road logic runs, and the next tick reset should discard any in-progress preview.

2. **Clicking RESET after panning the camera**
   Recreating `$camera` in `reset args` is required; otherwise the board would remain offset after reset.

3. **Clicking RESET multiple times quickly**
   Multiple `GTK.reset_next_tick` requests should be harmless, but the button handler should still return immediately after scheduling reset.

4. **Portrait or alternate layout sizes**
   `col: 21, w: 3` is correct for the current 24-column landscape layout. If portrait support is added later, revisit button placement or recompute all top-bar rects from a shared layout helper.

---

## Acceptance criteria

1. A `RESET` button appears on the far right of the top layout row.
2. The button matches the size and overall style of the existing mode buttons.
3. Clicking `RESET` does not place a building or road beneath the cursor.
4. Clicking `RESET` clears buildings, roads, road preview state, invalid-build feedback, and mode state by restarting the game state.
5. Clicking `RESET` also restores the camera to its initial position.
6. Existing `PAN`, `BUILD`, and `ROADS` buttons continue to work unchanged.

---

## Verification checklist

1. Launch the game and confirm `PAN`, `BUILD`, `ROADS` remain on the left and `RESET` appears on the far right of the same row.
2. Pan the camera, place buildings, and draw roads.
3. Click `RESET`.
4. Verify the grid returns to its original centered view.
5. Verify all placed buildings and roads are gone.
6. Verify road previews and temporary invalid-build highlights are cleared.
7. Verify the default mode is restored on the next tick.
8. Verify clicking the button area never triggers build or road placement.
