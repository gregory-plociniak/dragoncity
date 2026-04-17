# Plan: Clickable Mode Buttons via Layout API

## Goal

Replace the keyboard-driven mode toggles (`B` for build, `R` for roads) in [mygame/app/input_handler.rb](/Users/gregory/dragoncity/mygame/app/input_handler.rb) with on-screen **clickable buttons** that switch between `:pan`, `:build`, and `:roads` modes.

Button placement, sizing, and alignment should use DragonRuby's [`Layout`](/Users/gregory/dragoncity/docs/api/layout.md) API so the UI stays inside the safe area across screen sizes and orientations.

---

## Current behavior

`InputHandler#handle_mode_toggles` currently:

1. On `key_down.b`, toggles `args.state.mode` between `:build` and `:pan` and clears any road preview.
2. On `key_down.r`, toggles `args.state.mode` between `:roads` and `:pan` and clears any road preview.

Mode information is rendered as a single label in [mygame/app/grid_renderer.rb](/Users/gregory/dragoncity/mygame/app/grid_renderer.rb):

```ruby
text: "Mode: #{args.state.mode.upcase}  [B] build  [R] roads"
```

There are three implicit states: `:pan`, `:build`, `:roads`, but only two hotkeys, and `:pan` is reached indirectly by "untoggling" the active mode.

---

## Proposed approach

Introduce three explicit mode buttons — **Pan**, **Build**, **Roads** — rendered along the top of the screen using `Layout.rect`. Clicking a button sets `args.state.mode` directly. The currently-active mode is visually highlighted.

Button rectangles are computed once (cached on `args.state`) and reused for both rendering and hit-testing, mirroring the menu-item pattern in `docs/api/layout.md`.

### Persistent state

Add to `tick` in [mygame/app/main.rb](/Users/gregory/dragoncity/mygame/app/main.rb):

```ruby
args.state.mode_buttons ||= {
  pan:   Layout.rect(row: 0, col: 0, w: 3, h: 1),
  build: Layout.rect(row: 0, col: 3, w: 3, h: 1),
  roads: Layout.rect(row: 0, col: 6, w: 3, h: 1)
}
```

Each value is a Layout rect hash with `x`, `y`, `w`, `h`, and `center`. Using three consecutive cells of width `3` and height `1` on `row: 0` keeps the bar anchored to the top-left of the safe area with room for readable labels.

---

## Input flow changes

### New `handle_ui_click` step

In `InputHandler#process`, handle UI clicks **before** dispatching to mode-specific handlers so a click on a button doesn't also drop a building or start a road stroke on the tile beneath it:

```ruby
def process(args, camera)
  return if handle_ui_click(args)

  case args.state.mode
  when :pan   then handle_pan_input(args, camera)
  when :build then handle_build_input(args, camera)
  when :roads then handle_road_input(args, camera)
  end
end
```

`handle_ui_click` returns `true` when a button consumed the click, signalling downstream handlers to skip this frame.

### Button hit-testing

```ruby
def handle_ui_click(args)
  return false unless args.inputs.mouse.click

  args.state.mode_buttons.each do |mode, rect|
    next unless args.inputs.mouse.intersect_rect?(rect)

    change_mode(args, mode)
    return true
  end

  false
end

def change_mode(args, new_mode)
  return if args.state.mode == new_mode

  args.state.mode = new_mode
  clear_road_preview(args.state)
end
```

`change_mode` centralizes the side effect of leaving roads mode (clearing any in-progress preview), which `handle_mode_toggles` currently duplicates in both keyboard branches.

### Remove `handle_mode_toggles`

Delete the keyboard toggle method and its call from `process`. The `B` / `R` key bindings are fully replaced by button clicks.

---

## Rendering changes

Move mode UI out of the single status label in `GridRenderer` and into a dedicated button renderer. Options:

1. Add a `render_mode_buttons(args)` method inside `GridRenderer`.
2. Or, extract a small `UiRenderer` class if the UI layer grows further.

For this plan, keep it in `GridRenderer` to match current structure.

### Per-button rendering

For each `[mode, rect]` pair in `args.state.mode_buttons`:

1. Draw a filled background sprite using `path: :solid`.
2. Tint the active mode differently (for example brighter or with a distinct hue).
3. Draw a centered label using `rect.center.merge(...)` with `anchor_x: 0.5, anchor_y: 0.5`.

```ruby
def render_mode_buttons(args)
  args.state.mode_buttons.each do |mode, rect|
    active = args.state.mode == mode

    args.outputs.sprites << rect.merge(
      path: :solid,
      r: active ? 80 : 40,
      g: active ? 140 : 70,
      b: active ? 220 : 110,
      a: 220
    )

    args.outputs.labels << rect.center.merge(
      text: mode.to_s.upcase,
      r: 255, g: 255, b: 255,
      anchor_x: 0.5,
      anchor_y: 0.5
    )
  end
end
```

### Simplify the status label

The existing `"Mode: X  [B] build  [R] roads"` label is now redundant; either:

- remove it, or
- replace with a shorter hint (e.g. current mode name only) positioned below the button row.

Preferred: remove it. The active-button highlight already communicates the current mode.

---

## File changes

### `mygame/app/main.rb`

- Initialize `args.state.mode_buttons ||= { ... }` using `Layout.rect`.

### `mygame/app/input_handler.rb`

- Delete `handle_mode_toggles` and its call in `process`.
- Add `handle_ui_click(args)` that hit-tests each button rect and calls `change_mode`.
- Add `change_mode(args, new_mode)` that assigns the new mode and calls `clear_road_preview`.
- Call `handle_ui_click` first in `process` and short-circuit if it returns `true`.

### `mygame/app/grid_renderer.rb`

- Add `render_mode_buttons(args)` and call it from `render`.
- Remove or simplify the `"Mode: …"` status label.

---

## Edge cases

1. **Click lands on a button while in `:build` or `:roads` mode.**
   `handle_ui_click` runs before `handle_build_input` / `handle_road_input`, so the click switches modes instead of placing a building or road.

2. **Drag starts on a button.**
   `handle_road_input` uses `mouse.button_left` and `mouse.key_down.left`. If a drag begins on a button, `handle_ui_click` consumes the click on that frame, but subsequent frames in which the button is held are still valid `button_left == true`. To avoid a stale drag starting the moment the cursor leaves the button:

   - On successful UI click, also call `clear_road_preview` (already done inside `change_mode` — confirm it runs even when the new mode equals the old mode if the user re-clicks the active button). Simplest rule: always clear preview on any UI click, even if mode did not change.

3. **Button rects computed once per session.**
   `Layout.rect` return values depend on orientation. If the game supports runtime orientation changes, recompute `mode_buttons` when `Layout.portrait?` / `Layout.landscape?` flips. For now, compute once in `tick` with `||=`; revisit if portrait mode is added.

4. **Roads mode in-progress when user clicks a button.**
   `change_mode` calls `clear_road_preview`, which wipes `road_preview`, `road_drag_last`, and `road_drag_kind`. The in-progress stroke is discarded rather than committed — consistent with current keyboard-toggle behavior.

---

## Acceptance criteria

1. Three buttons (**PAN**, **BUILD**, **ROADS**) are visible at the top of the screen, placed via `Layout.rect`.
2. Clicking a button switches `args.state.mode` to the corresponding value.
3. The active button is visually distinct from the inactive buttons.
4. Clicking a button while in roads mode with an active preview discards the preview (matches current `R`-key behavior).
5. Clicking a button does **not** place a building or road on the tile beneath the cursor.
6. Building placement in `:build` mode and road dragging in `:roads` mode still work everywhere outside the button strip.
7. The old `B` and `R` keyboard toggles no longer affect mode state.
8. The previous `"Mode: … [B] build [R] roads"` status label is removed or reduced to non-redundant content.

---

## Verification checklist

1. Launch the game; the three mode buttons appear along the top, none obstructing the grid.
2. Click **BUILD**; mode label / highlight updates; clicking a tile places a building.
3. Click **ROADS**; drag across tiles; preview appears; release commits the road.
4. While dragging in roads mode, click **PAN** mid-stroke: preview disappears and no partial placement remains.
5. Press `B` and `R`: mode does **not** change (keyboard bindings removed).
6. Click the currently active button: no state corruption, no building / road placed under the button.
7. Verify button rectangles stay within the safe area by temporarily rendering `Layout.debug_primitives`.
