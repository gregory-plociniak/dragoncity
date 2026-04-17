class BuildingPlacer
  def handle_click(args, camera)
    return unless args.inputs.mouse.click

    col, row = GridCoordinates.screen_to_grid(
      args.inputs.mouse.click.x,
      args.inputs.mouse.click.y,
      camera
    )
    return unless GridCoordinates.in_bounds?(col, row)

    key = GridCoordinates.tile_key(col, row)
    if args.state.buildings[key]
      args.state.buildings.delete(key)
    elsif !args.state.roads[key] && road_nearby?(args.state.roads, col, row)
      args.state.buildings[key] = true
    else
      flash_invalid(args.state, key)
    end
  end

  def prune_expired(state)
    state.invalid_build_tiles.delete_if do |_key, expires_at|
      expires_at < state.frame_index
    end
  end

  private

  def road_nearby?(roads, col, row)
    [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]].any? do |delta_col, delta_row|
      roads[GridCoordinates.tile_key(col + delta_col, row + delta_row)]
    end
  end

  def flash_invalid(state, key)
    state.invalid_build_tiles[key] = state.frame_index + BUILD_INVALID_FLASH_FRAMES
  end
end
