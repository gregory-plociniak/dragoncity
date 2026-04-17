class CarManager
  AMBULANCE_SPRITE_DIMENSIONS = {
    'sprites/ambulance_NE.png' => [35, 31],
    'sprites/ambulance_NW.png' => [35, 31],
    'sprites/ambulance_SE.png' => [35, 35],
    'sprites/ambulance_SW.png' => [35, 36]
  }
  MIN_PAIR_DISTANCE = 4
  DEFAULT_SPEED = 0.02
  # Main lane-distance control. Increase to push cars farther from the road
  # centerline; decrease to pull them back toward the middle.
  LANE_OFFSET_PIXELS = 5
  # Global vertical placement for the car sprite after lane math. Make this
  # more negative to raise all cars, or closer to 0 to lower them.
  GLOBAL_CAR_Y_BIAS = 25
  # Sprite-art compensation after the geometric lane offset. Use this when a
  # specific travel direction still rides too close to a sidewalk because the
  # road art is not visually centered on the tile.
  DIRECTIONAL_ART_BIAS = {
    [1, 0] => [0, 0], # bottom-right travel
    [-1, 0] => [0, 0],
    [0, 1] => [0, 0],
    [0, -1] => [-15, -8] # top-right travel: move left slightly and raise toward the asphalt
  }.freeze
  # Screen-space lane shift tuned by eye. The offset is computed from the
  # segment's actual projected screen vector, then rotated to the traveler's
  # right side so it stays perpendicular to the road in all four directions.

  def initialize(pathfinder = RoadPathfinder.new)
    @pathfinder = pathfinder
  end

  def recompute(state)
    building_tiles = state.buildings.keys.map { |key| parse_key(key) }
    existing_by_key = state.cars.each_with_object({}) { |car, hash| hash[car[:pair_key]] = car }

    new_cars = []
    building_tiles.combination(2).each do |b1, b2|
      next unless pair_far_enough?(b1, b2)

      endpoints = [b1, b2].sort
      key = pair_key_for(endpoints)
      existing = existing_by_key[key]

      car = if existing
              update_existing_car(state.roads, existing, endpoints)
            else
              spawn_new_car(state.roads, endpoints, key)
            end

      new_cars << car if car
    end

    state.cars = new_cars
  end

  def tick(state)
    survivors = []
    state.cars.each do |car|
      survivors << car if advance_car(state, car)
    end
    state.cars = survivors
  end

  def render(args, camera)
    args.state.cars.each do |car|
      path = car[:leg][:path]
      from = path[car[:step_index]]
      to   = path[car[:step_index] + 1]
      next unless from && to

      delta_col = to[0] - from[0]
      delta_row = to[1] - from[1]
      sx, sy = interpolated_screen_position(camera, from, to, car[:progress])
      lane_dx, lane_dy = lane_offset_for(path, car[:step_index], car[:progress])
      sx += lane_dx
      sy += lane_dy

      sprite_path = sprite_for_delta(delta_col, delta_row)
      w, h = AMBULANCE_SPRITE_DIMENSIONS[sprite_path]

      args.outputs.sprites << {
        x: sx - w / 2,
        y: sy - TILE_H / 2 - h / 2 + GLOBAL_CAR_Y_BIAS,
        w: w,
        h: h,
        path: sprite_path
      }
    end
  end

  private

  def advance_car(state, car)
    car[:progress] += car[:speed]
    while car[:progress] >= 1.0
      car[:progress] -= 1.0
      car[:step_index] += 1

      next if car[:step_index] < car[:leg][:path].size - 1

      next_leg = plan_next_leg(state.roads, car)
      return false unless next_leg

      car[:leg] = next_leg
      car[:step_index] = 0
      car[:pending_repath] = false
    end
    true
  end

  def plan_next_leg(roads, car)
    new_direction = 1 - car[:leg][:direction]
    origin_building, destination_building = endpoints_for_direction(car[:endpoints], new_direction)

    path = best_road_path(roads, origin_building, destination_building)
    return nil unless path
    return nil if path.size < 2

    { path: path, direction: new_direction }
  end

  def endpoints_for_direction(endpoints, direction)
    direction == 0 ? endpoints : endpoints.reverse
  end

  def update_existing_car(roads, car, endpoints)
    car[:endpoints] = endpoints

    if current_leg_valid?(roads, car)
      car[:pending_repath] = true
      return car
    end

    recover_broken_leg(roads, car) ? car : nil
  end

  def current_leg_valid?(roads, car)
    path = car[:leg][:path]
    return false unless path
    idx = car[:step_index]
    return false if idx >= path.size - 1

    (idx...(path.size - 1)).each do |i|
      from_col, from_row = path[i]
      to_col, to_row = path[i + 1]
      return false unless RoadGraph.road_tile?(roads, from_col, from_row)
      return false unless RoadGraph.road_tile?(roads, to_col, to_row)
      return false unless RoadGraph.traversable_edge?(roads, from_col, from_row, to_col, to_row)
    end
    true
  end

  def recover_broken_leg(roads, car)
    path = car[:leg][:path]
    current_tile = path[car[:step_index]]
    goal_tile = path[-1]

    return false unless current_tile && goal_tile
    return false unless RoadGraph.road_tile?(roads, current_tile[0], current_tile[1])
    return false unless RoadGraph.road_tile?(roads, goal_tile[0], goal_tile[1])

    new_path = @pathfinder.find_path(roads, current_tile, goal_tile)
    return false unless new_path
    return false if new_path.size < 2

    car[:leg] = { path: new_path, direction: car[:leg][:direction] }
    car[:step_index] = 0
    car[:progress] = 0.0
    car[:pending_repath] = false
    true
  end

  def spawn_new_car(roads, endpoints, key)
    path = best_road_path(roads, endpoints[0], endpoints[1])
    return nil unless path
    return nil if path.size < 2

    {
      pair_key: key,
      endpoints: endpoints,
      leg: { path: path, direction: 0 },
      step_index: 0,
      progress: 0.0,
      speed: DEFAULT_SPEED,
      pending_repath: false
    }
  end

  def pair_far_enough?(b1, b2)
    [(b1[0] - b2[0]).abs, (b1[1] - b2[1]).abs].max >= MIN_PAIR_DISTANCE
  end

  def pair_key_for(endpoints)
    "#{endpoints[0][0]},#{endpoints[0][1]}|#{endpoints[1][0]},#{endpoints[1][1]}"
  end

  def parse_key(key)
    col, row = key.split(',')
    [col.to_i, row.to_i]
  end

  def best_road_path(roads, start_building, goal_building)
    start_access_tiles = RoadGraph.building_access_tiles(roads, start_building[0], start_building[1])
    goal_access_tiles = RoadGraph.building_access_tiles(roads, goal_building[0], goal_building[1])
    return nil if start_access_tiles.empty? || goal_access_tiles.empty?

    best_path = nil

    start_access_tiles.each do |start_tile|
      goal_access_tiles.each do |goal_tile|
        candidate_path = @pathfinder.find_path(roads, start_tile, goal_tile)
        next unless candidate_path
        next unless better_path?(candidate_path, best_path)

        best_path = candidate_path
      end
    end

    best_path
  end

  def better_path?(candidate_path, current_best_path)
    return true unless current_best_path

    return true if candidate_path.length < current_best_path.length
    return false if candidate_path.length > current_best_path.length

    compare_paths(candidate_path, current_best_path) < 0
  end

  def compare_paths(left_path, right_path)
    left_path.each_with_index do |(left_col, left_row), index|
      right_col, right_row = right_path[index]
      left_order = tile_order(left_col, left_row)
      right_order = tile_order(right_col, right_row)
      next if left_order == right_order

      return left_order < right_order ? -1 : 1
    end

    0
  end

  def tile_order(col, row)
    row * GRID_SIZE + col
  end

  def interpolated_screen_position(camera, from, to, progress)
    from_sx, from_sy = camera.world_to_screen(from[0], from[1], TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)
    to_sx, to_sy = camera.world_to_screen(to[0], to[1], TILE_W, TILE_H, ORIGIN_X, ORIGIN_Y)

    sx = from_sx + (to_sx - from_sx) * progress
    sy = from_sy + (to_sy - from_sy) * progress
    [sx, sy]
  end

  def lane_offset_for(path, step_index, progress)
    from = path[step_index]
    to = path[step_index + 1]
    return [0, 0] unless from && to

    total_direction_offset(to[0] - from[0], to[1] - from[1])
  end

  def right_hand_lane_offset(delta_col, delta_row)
    screen_dx, screen_dy = projected_step_vector(delta_col, delta_row)
    # Flip these signs if the car ends up on the left side of travel instead of the right.
    right_dx = screen_dy
    right_dy = -screen_dx
    length = Math.sqrt((right_dx * right_dx) + (right_dy * right_dy))
    return [0, 0] if length.zero?

    [
      # LANE_OFFSET_PIXELS above is the main knob for how dramatic the lane shift looks.
      right_dx / length * LANE_OFFSET_PIXELS,
      right_dy / length * LANE_OFFSET_PIXELS
    ]
  end

  def total_direction_offset(delta_col, delta_row)
    lane_dx, lane_dy = right_hand_lane_offset(delta_col, delta_row)
    bias_dx, bias_dy = art_bias_for(delta_col, delta_row)
    [lane_dx + bias_dx, lane_dy + bias_dy]
  end

  def art_bias_for(delta_col, delta_row)
    # Fine-tune per-direction sidewalk compensation here. Negative Y raises the
    # car on screen; positive Y lowers it.
    DIRECTIONAL_ART_BIAS.fetch([delta_col, delta_row], [0, 0])
  end

  def projected_step_vector(delta_col, delta_row)
    [
      (delta_col - delta_row) * (TILE_W / 2.0),
      -(delta_col + delta_row) * (TILE_W / 4.0)
    ]
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
