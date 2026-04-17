class GridRenderer
  BUILDING_TILE_PATH = 'sprites/building01.png'
  GROUND_TILE_PATH = 'sprites/ground.png'
  PREVIEW_ALPHA = 128

  def render(args, camera)
    GRID_SIZE.times do |row|
      GRID_SIZE.times do |col|
        sx, sy = camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
        tile_key = "#{col},#{row}"

        draw_tile(args, sx, sy, GROUND_TILE_PATH)

        road_path = road_sprite_path(args.state.roads[tile_key])
        draw_tile(args, sx, sy, road_path) if road_path

        preview_path = road_sprite_path(args.state.road_preview[tile_key])
        draw_tile(args, sx, sy, preview_path, a: PREVIEW_ALPHA) if preview_path

        draw_tile(args, sx, sy, BUILDING_TILE_PATH) if args.state.buildings[tile_key]
      end
    end

    args.outputs.labels << {
      x: 10,
      y: 710,
      text: "Mode: #{args.state.mode.upcase}  [B] build  [R] roads",
      r: 255, g: 255, b: 255
    }
  end

  private

  def draw_tile(args, sx, sy, path, a: 255)
    tile_w, tile_h = tile_dimensions(path)
    tile_x_offset, tile_y_offset = tile_offsets(path)

    args.outputs.sprites << {
      x: sx - tile_w / 2 + tile_x_offset,
      y: sy - tile_h + tile_y_offset,
      w: tile_w,
      h: tile_h,
      path: path,
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
