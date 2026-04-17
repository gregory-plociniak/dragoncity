class GridRenderer
  BUILDING_TILE_PATH = 'sprites/building01.png'
  GROUND_TILE_PATH = 'sprites/ground.png'
  PREVIEW_ALPHA = 128
  INVALID_GROUND_COLOR = {
    r: 255,
    g: 110,
    b: 110
  }

  def render(args, camera)
    GRID_SIZE.times do |row|
      GRID_SIZE.times do |col|
        sx, sy = camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
        tile_key = "#{col},#{row}"
        road_path = road_sprite_path(args.state.roads[tile_key])

        if road_path
          draw_tile(args, sx, sy, road_path)
        else
          draw_tile(args, sx, sy, GROUND_TILE_PATH, **ground_tile_color(args.state, tile_key))
        end

        preview_path = road_sprite_path(args.state.road_preview[tile_key])
        draw_tile(args, sx, sy, preview_path, a: PREVIEW_ALPHA) if preview_path

        draw_tile(args, sx, sy, BUILDING_TILE_PATH) if args.state.buildings[tile_key]
      end
    end

    render_mode_buttons(args)
    render_reset_button(args)
  end

  private

  def render_mode_buttons(args)
    args.state.mode_buttons.each do |mode, rect|
      render_button(args, rect, mode.to_s.upcase, active: args.state.mode == mode)
    end
  end

  def render_reset_button(args)
    render_button(args, args.state.reset_button, 'RESET')
  end

  def render_button(args, rect, label, active: false)
    args.outputs.sprites << rect.merge(
      path: :solid,
      r: active ? 80 : 40,
      g: active ? 140 : 70,
      b: active ? 220 : 110,
      a: 220
    )

    args.outputs.labels << rect.center.merge(
      text: label,
      r: 255, g: 255, b: 255,
      anchor_x: 0.5,
      anchor_y: 0.5
    )
  end

  def ground_tile_color(state, tile_key)
    return {} unless state.invalid_build_tiles[tile_key]

    INVALID_GROUND_COLOR
  end

  def draw_tile(args, sx, sy, path, r: 255, g: 255, b: 255, a: 255)
    tile_w, tile_h = tile_dimensions(path)
    tile_x_offset, tile_y_offset = tile_offsets(path)

    args.outputs.sprites << {
      x: sx - tile_w / 2 + tile_x_offset,
      y: sy - tile_h + tile_y_offset,
      w: tile_w,
      h: tile_h,
      path: path,
      r: r,
      g: g,
      b: b,
      a: a
    }
  end

  def road_sprite_path(road_kind)
    case road_kind
    when :ne
      'sprites/road_NE.png'
    when :nw
      'sprites/road_NW.png'
    when :cross
      'sprites/crossroad.png'
    end
  end

  def tile_dimensions(path)
    if path == BUILDING_TILE_PATH
      [133, 127]
    else
      [TILE_W, TILE_H]
    end
  end

  def tile_offsets(path)
    if path == BUILDING_TILE_PATH
      [BUILDING_TILE_X_OFFSET, BUILDING_TILE_Y_OFFSET]
    else
      [0, 0]
    end
  end
end
