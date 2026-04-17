class IsometricCamera
  attr_accessor :x, :y

  def initialize
    @x = 0
    @y = 0
  end

  def world_to_screen(col, row, tile_w, tile_h, origin_x, origin_y)
    sx = origin_x + (col - row) * (tile_w / 2) + @x
    sy = origin_y - (col + row) * (tile_w / 4) + @y
    [sx, sy]
  end
end
