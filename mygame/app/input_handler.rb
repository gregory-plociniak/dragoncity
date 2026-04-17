class InputHandler
  def process(args, camera)
    return if handle_ui_click(args)

    case args.state.mode
    when :pan
      handle_pan_input(args, camera)
    when :build
      handle_build_input(args, camera)
    when :roads
      handle_road_input(args, camera)
    end
  end

  private

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
    clear_road_preview(args.state)
    args.state.mode = new_mode
  end

  def handle_pan_input(args, camera)
    camera.x -= PAN_SPEED if args.inputs.keyboard.right
    camera.x += PAN_SPEED if args.inputs.keyboard.left
    camera.y -= PAN_SPEED if args.inputs.keyboard.up
    camera.y += PAN_SPEED if args.inputs.keyboard.down

    if args.inputs.mouse.button_left && args.inputs.mouse.moved
      camera.x += args.inputs.mouse.relative_x
      camera.y += args.inputs.mouse.relative_y
    end
  end

  def handle_build_input(args, camera)
    return unless args.inputs.mouse.click

    col, row = screen_to_grid(
      args.inputs.mouse.click.x,
      args.inputs.mouse.click.y,
      TILE_W, ORIGIN_X, ORIGIN_Y, camera
    )
    return unless in_bounds?(col, row)

    key = tile_key(col, row)
    if args.state.buildings[key]
      args.state.buildings.delete(key)
    else
      args.state.buildings[key] = true
    end
  end

  def handle_road_input(args, camera)
    mouse = args.inputs.mouse
    clear_road_preview(args.state) if mouse.key_down.left

    if mouse.button_left
      col, row = screen_to_grid(mouse.x, mouse.y, TILE_W, ORIGIN_X, ORIGIN_Y, camera)
      if in_bounds?(col, row)
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
      commit_road_preview(args.state)
      clear_road_preview(args.state)
    end
  end

  def screen_to_grid(mx, my, tile_w, origin_x, origin_y, camera)
    dx =  (mx - origin_x - camera.x).to_f
    dy = -(my - origin_y - camera.y).to_f

    u = dx / (tile_w / 2.0)
    v = dy / (tile_w / 4.0)

    col = ((u + v) / 2.0).floor
    row = ((v - u) / 2.0).floor
    [col, row]
  end

  def in_bounds?(col, row)
    col >= 0 && col < GRID_SIZE && row >= 0 && row < GRID_SIZE
  end

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
    key = tile_key(col, row)
    roads[key] = merge_road(roads[key], road_kind)
  end

  def apply_preview_road(preview, col, row, road_kind)
    apply_road(preview, col, row, road_kind)
  end

  def commit_road_preview(state)
    state.road_preview.each do |key, road_kind|
      state.roads[key] = merge_road(state.roads[key], road_kind)
    end
  end

  def merge_road(existing, incoming)
    return incoming unless existing
    return existing if existing == incoming

    :cross
  end

  def tile_key(col, row)
    "#{col},#{row}"
  end

  def clear_road_preview(state)
    state.road_preview = {}
    state.road_drag_last = nil
    state.road_drag_kind = nil
  end
end
