class GridRenderer
  BUILDING_TILE_PATH = 'sprites/building01.png'

  def render(args, camera)
    GRID_SIZE.times do |row|
      GRID_SIZE.times do |col|
        sx, sy = camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
        building_present = args.state.buildings["#{col},#{row}"]
        road_path = road_sprite_path(args.state.roads["#{col},#{row}"])
        tile_path = building_present ? BUILDING_TILE_PATH : (road_path || 'sprites/ground.png')
        tile_w, tile_h = tile_dimensions(tile_path)
        tile_x_offset, tile_y_offset = tile_offsets(tile_path)

        args.outputs.sprites << {
          x: sx - tile_w / 2 + tile_x_offset,
          y: sy - tile_h + tile_y_offset,
          w: tile_w,
          h: tile_h,
          path: tile_path
        }
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
