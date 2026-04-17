class CarManager
  AMBULANCE_SPRITE_DIMENSIONS = {
    'sprites/ambulance_NE.png' => [35, 31],
    'sprites/ambulance_NW.png' => [35, 31],
    'sprites/ambulance_SE.png' => [35, 35],
    'sprites/ambulance_SW.png' => [35, 36]
  }
  MIN_PAIR_DISTANCE = 4
  DEFAULT_SPEED = 0.02

  def recompute(state)
    building_tiles = state.buildings.keys.map { |key| parse_key(key) }

    new_cars = []
    building_tiles.combination(2).each do |(c1, r1), (c2, r2)|
      next unless [(c1 - c2).abs, (r1 - r2).abs].max >= MIN_PAIR_DISTANCE

      path = build_loop_path(c1, r1, c2, r2)
      next if path.size < 2

      new_cars << preserve_progress_or_new(state.cars, path)
    end

    state.cars = new_cars
  end

  def tick(state)
    state.cars.each do |car|
      car[:progress] += car[:speed]
      while car[:progress] >= 1.0
        car[:progress] -= 1.0
        car[:step_index] = (car[:step_index] + 1) % car[:path].size
      end
    end
  end

  def render(args, camera)
    args.state.cars.each do |car|
      path = car[:path]
      from = path[car[:step_index]]
      to   = path[(car[:step_index] + 1) % path.size]

      from_sx, from_sy = camera.world_to_screen(from[0], from[1], TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
      to_sx, to_sy     = camera.world_to_screen(to[0], to[1], TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)

      t = car[:progress]
      sx = from_sx + (to_sx - from_sx) * t
      sy = from_sy + (to_sy - from_sy) * t

      sprite_path = sprite_for_delta(to[0] - from[0], to[1] - from[1])
      w, h = AMBULANCE_SPRITE_DIMENSIONS[sprite_path]

      args.outputs.sprites << {
        x: sx - w / 2,
        y: sy - TILE_H / 2 - h / 2,
        w: w,
        h: h,
        path: sprite_path
      }
    end
  end

  private

  def parse_key(key)
    col, row = key.split(',')
    [col.to_i, row.to_i]
  end

  def build_loop_path(c1, r1, c2, r2)
    corners = [[c1, r1], [c2, r1], [c2, r2], [c1, r2]]
    path = []
    corners.each_with_index do |from, i|
      to = corners[(i + 1) % corners.size]
      col, row = from
      while [col, row] != to
        path << [col, row]
        col += (to[0] <=> col)
        row += (to[1] <=> row)
      end
    end
    path
  end

  def preserve_progress_or_new(existing_cars, path)
    existing = existing_cars.find { |car| car[:path] == path }
    return existing if existing

    {
      path: path,
      step_index: 0,
      progress: 0.0,
      speed: DEFAULT_SPEED
    }
  end

  def sprite_for_delta(delta_col, delta_row)
    if delta_col > 0
      'sprites/ambulance_SE.png'
    elsif delta_col < 0
      'sprites/ambulance_NW.png'
    elsif delta_row > 0
      'sprites/ambulance_SW.png'
    else
      'sprites/ambulance_NE.png'
    end
  end
end
