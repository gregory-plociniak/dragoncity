# Plan: Buildings Require Nearby Roads

## Goal

Only allow new buildings to be placed when a road is on the target tile or directly adjacent to it. If placement is rejected, briefly tint that ground tile to give immediate feedback.

## Implementation

### Placement rule

- Keep the existing `build` mode click handling.
- If the clicked tile already has a building, remove it as today.
- If the tile is empty, only place a building when a road exists at:
  - the clicked tile itself, or
  - one of the four orthogonally adjacent tiles.
- If no road is nearby, do not place the building.

### Feedback state

- Track invalid placement flashes in `args.state.invalid_build_tiles`.
- Store each flash as `"col,row" => expires_at_frame`.
- Increment a simple `args.state.frame_index` every tick.
- Prune expired flashes in `InputHandler` so the state stays small.

### Rendering

- Always render the ground sprite first.
- When a tile is currently flagged in `invalid_build_tiles`, tint only the ground tile with a warm red color.
- Render roads after ground, then preview roads, then buildings.

## File changes

### `mygame/app/main.rb`

- Add `BUILD_INVALID_FLASH_FRAMES`.
- Initialize `invalid_build_tiles` and `frame_index`.
- Increment `frame_index` each tick.

### `mygame/app/input_handler.rb`

- Add a `road_nearby?` helper for same-tile and orthogonal road checks.
- Reject new building placement when no nearby road exists.
- Record a short-lived invalid-placement flash instead.
- Prune expired flash entries each frame.

### `mygame/app/grid_renderer.rb`

- Split ground and road rendering into separate layers.
- Tint the ground tile when invalid placement feedback is active.

## Acceptance Criteria

1. Existing buildings can still be removed with a click in build mode.
2. New buildings only place when a road is on or next to the target tile.
3. Invalid placements leave the world state unchanged.
4. Invalid placement briefly changes the clicked ground tile color.
5. Roads still render below buildings.
