class RoadBuilder
  def handle_input(args, camera)
    mouse = args.inputs.mouse
    clear_preview(args.state) if mouse.key_down.left

    if mouse.button_left
      col, row = GridCoordinates.screen_to_grid(mouse.x, mouse.y, camera)
      if GridCoordinates.in_bounds?(col, row)
        current_tile = [col, row]
        previous_tile = args.state.road_drag_last

        if previous_tile.nil?
          args.state.road_drag_last = current_tile
        elsif previous_tile != current_tile
          road_kind = delta_to_road_kind(
            current_tile[0] - previous_tile[0],
            current_tile[1] - previous_tile[1]
          )

          if road_kind
            args.state.road_drag_kind ||= road_kind
          end

          if road_kind == args.state.road_drag_kind
            each_straight_step(previous_tile, current_tile) do |from_col, from_row, to_col, to_row|
              apply_preview_road(args.state.road_preview, from_col, from_row, road_kind)
              apply_preview_road(args.state.road_preview, to_col, to_row, road_kind)
            end

            args.state.road_drag_last = current_tile
          end
        end
      end
    end

    if mouse.key_up.left
      committed = commit_preview(args.state)
      $car_manager.recompute(args.state) if committed
      clear_preview(args.state)
    end
  end

  def clear_preview(state)
    state.road_preview = {}
    state.road_drag_last = nil
    state.road_drag_kind = nil
  end

  def commit_preview(state)
    return false if state.road_preview.empty?

    state.road_preview.each do |key, road_kind|
      state.roads[key] = merge_road(state.roads[key], road_kind)
    end

    true
  end

  private

  def each_straight_step(from_tile, to_tile)
    from_col, from_row = from_tile
    to_col, to_row = to_tile

    if from_row == to_row
      step = to_col > from_col ? 1 : -1
      col = from_col
      while col != to_col
        next_col = col + step
        yield col, from_row, next_col, from_row
        col = next_col
      end
    elsif from_col == to_col
      step = to_row > from_row ? 1 : -1
      row = from_row
      while row != to_row
        next_row = row + step
        yield from_col, row, from_col, next_row
        row = next_row
      end
    end
  end

  def delta_to_road_kind(delta_col, delta_row)
    if delta_row == 0
      :ne
    elsif delta_col == 0
      :nw
    end
  end

  def apply_road(roads, col, row, road_kind)
    key = GridCoordinates.tile_key(col, row)
    roads[key] = merge_road(roads[key], road_kind)
  end

  def apply_preview_road(preview, col, row, road_kind)
    apply_road(preview, col, row, road_kind)
  end

  def merge_road(existing, incoming)
    return incoming unless existing
    return existing if existing == incoming

    :cross
  end
end
