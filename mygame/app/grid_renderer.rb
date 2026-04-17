class GridRenderer
  def render(args, camera)
    GRID_SIZE.times do |row|
      GRID_SIZE.times do |col|
        sx, sy = camera.world_to_screen(col, row, TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)

        args.outputs.sprites << {
          x: sx - TILE_W / 2,
          y: sy - TILE_H,
          w: TILE_W,
          h: TILE_H,
          path: 'sprites/ground.png'
        }

        road_path = road_sprite_path(args.state.roads["#{col},#{row}"])
        if road_path
          args.outputs.sprites << {
            x: sx - TILE_W / 2,
            y: sy - TILE_H,
            w: TILE_W,
            h: TILE_H,
            path: road_path
          }
        end

        if args.state.buildings["#{col},#{row}"]
          bw = (TILE_W * BUILDING_SCALE).round
          bh = (TILE_H * BUILDING_SCALE).round
          args.outputs.sprites << {
            x: sx - bw / 2,
            y: sy - bh + BUILDING_Y_OFFSET,
            w: bw,
            h: bh,
            path: 'sprites/building1.png'
          }
        end
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
      'sprites/road_NW.png'
    when :nw
      'sprites/road_NE.png'
    when :cross
      'sprites/crossroad.png'
    end
  end
end
