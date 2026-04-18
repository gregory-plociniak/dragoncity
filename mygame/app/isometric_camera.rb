class IsometricCamera
  attr_accessor :x, :y

  def initialize
    @x = 0
    @y = 0
  end

  # footprint_h is the diamond's projected ground height, NOT the sprite height.
  # Sprite images include elevation pixels above the diamond, so TILE_H > footprint_h.
  # For a standard 2:1 iso tile, footprint_h == tile_w / 2.
  def world_to_screen(col, row, tile_w, footprint_h, origin_x, origin_y)
    sx = origin_x + (col - row) * (tile_w / 2) + @x
    sy = origin_y - (col + row) * (footprint_h / 2) + @y
    [sx, sy]
  end
end
