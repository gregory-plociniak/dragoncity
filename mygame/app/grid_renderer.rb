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
      end
    end
  end
end
