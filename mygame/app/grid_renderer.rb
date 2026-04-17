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
      text: "Mode: #{args.state.mode.upcase}  [B] to toggle",
      r: 255, g: 255, b: 255
    }
  end
end
