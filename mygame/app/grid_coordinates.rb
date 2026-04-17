module GridCoordinates
  def self.screen_to_grid(mx, my, camera)
    dx =  (mx - ORIGIN_X - camera.x).to_f
    dy = -(my - ORIGIN_Y - camera.y).to_f

    u = dx / (TILE_W / 2.0)
    v = dy / (TILE_W / 4.0)

    col = ((u + v) / 2.0).floor
    row = ((v - u) / 2.0).floor
    [col, row]
  end

  def self.in_bounds?(col, row)
    col >= 0 && col < GRID_SIZE && row >= 0 && row < GRID_SIZE
  end

  def self.tile_key(col, row)
    "#{col},#{row}"
  end
end
