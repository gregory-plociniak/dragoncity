class CarManager
  AMBULANCE_SPRITE_DIMENSIONS = {
    'sprites/ambulance_NE.png' => [35, 31],
    'sprites/ambulance_NW.png' => [35, 31],
    'sprites/ambulance_SE.png' => [35, 35],
    'sprites/ambulance_SW.png' => [35, 36]
  }
  MIN_PAIR_DISTANCE = 4
  DEFAULT_SPEED = 0.02
  CROSSOVER_THRESHOLD = 0.5
  CROSSOVER_EPSILON = 0.001
  ALL_WAY_STOP_LINE_PROGRESS = 0.8
  STOP_BRAKE_PER_TICK = 0.003
  STOP_ACCEL_PER_TICK = 0.004
  STALL_TICKS_BEFORE_REPATH = 180
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

    projected_slot_occupancy = build_slot_occupancy(state.cars)
    new_cars = []
    building_tiles.combination(2).each do |b1, b2|
      next unless pair_far_enough?(b1, b2)

      endpoints = [b1, b2].sort
      key = pair_key_for(endpoints)
      existing = existing_by_key[key]

      car = if existing
              update_existing_car(state.roads, existing, endpoints)
            else
              spawn_new_car(state.roads, endpoints, key, projected_slot_occupancy)
            end

      next unless car

      new_cars << car
      projected_slot_occupancy[current_slot(car)] = car unless existing
    end

    state.cars = new_cars
  end

  def tick(state)
    state.cars.each { |car| prepare_car_for_tick(state, car) }
    state.car_slot_occupancy = build_slot_occupancy(state.cars)
    midpoint_denied = resolve_midpoint_crossings(state.cars, state.car_slot_occupancy)
    stop_denied = resolve_all_way_stops(state, state.cars)
    step_denied = resolve_step_crossings(state.cars, state.car_slot_occupancy)

    survivors = []
    state.cars.each do |car|
      survivors << car if advance_car(
        state,
        car,
        midpoint_denied.include?(car),
        stop_denied.include?(car),
        step_denied.include?(car)
      )
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

  def advance_car(state, car, midpoint_denied, stop_denied, step_denied)
    stop_crossroad = stop_controlled_crossroad_for(state.roads, car)

    if midpoint_denied
      clamp_below_midpoint(car)
      record_stall(state, car)
      return true
    end

    if stop_denied
      clamp_below_stop_line(car)
      reset_stall(car)
      return true
    end

    if step_denied
      if waits_at_stop_line_without_go_token?(car, stop_crossroad)
        clamp_below_stop_line(car)
        reset_stall(car)
      elsif stop_crossroad && car[:stop_go_token] == stop_crossroad &&
            car[:progress] <= ALL_WAY_STOP_LINE_PROGRESS + CROSSOVER_EPSILON
        clamp_below_stop_line(car)
        record_stall(state, car)
      else
        clamp_below_step(car)
        record_stall(state, car)
      end
      return true
    end

    car[:progress] += movement_speed(car)
    if exiting_owned_crossroad?(car) && car[:progress] >= CROSSOVER_THRESHOLD
      clear_stop_control_state(car)
    end

    if stop_crossroad && car[:stop_go_token] != stop_crossroad &&
       car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS
      car[:progress] = ALL_WAY_STOP_LINE_PROGRESS
      car[:current_speed] = 0.0
      car[:stop_arrival_frame] ||= state.frame_index
      reset_stall(car)
      return true
    end

    reset_stall(car)
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

  def clamp_below_midpoint(car)
    car[:progress] = [car[:progress] + movement_speed(car), CROSSOVER_THRESHOLD - CROSSOVER_EPSILON].min
  end

  def clamp_below_stop_line(car)
    car[:progress] = [car[:progress] + movement_speed(car), ALL_WAY_STOP_LINE_PROGRESS].min
    car[:current_speed] = 0.0 if car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS
  end

  def clamp_below_step(car)
    car[:progress] = [car[:progress] + movement_speed(car), 1.0 - CROSSOVER_EPSILON].min
  end

  def reset_stall(car)
    car[:stall_ticks] = 0
  end

  def record_stall(state, car)
    car[:stall_ticks] = (car[:stall_ticks] || 0) + 1
    if car[:stall_ticks] >= STALL_TICKS_BEFORE_REPATH
      try_mid_leg_repath(state, car)
      car[:stall_ticks] = 0
    end
  end

  def build_slot_occupancy(cars)
    occupancy = {}
    cars.each do |car|
      slot = current_slot(car)
      occupancy[slot] = car if slot
    end
    occupancy
  end

  def current_slot(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    return nil unless path && path[idx]

    from = path[idx]
    to = path[idx + 1]
    if from && to
      half = car[:progress] < CROSSOVER_THRESHOLD ? :first : :second
      return [from[0], from[1], to[0], to[1], half]
    end

    return [path[idx - 1][0], path[idx - 1][1], from[0], from[1], :second] if idx.positive? && path[idx - 1]

    [from[0], from[1], from[0], from[1], :second]
  end

  def resolve_midpoint_crossings(cars, occupancy)
    intents = cars.filter_map { |car| midpoint_intent(car) }
    resolve_gate_crossings(intents, occupancy)
  end

  def resolve_all_way_stops(state, cars)
    denied = []

    cars
      .group_by { |car| active_stop_controlled_crossroad_for(state.roads, car) }
      .each do |crossroad, group|
        next unless crossroad

        waiting_group = group.select do |car|
          at_or_past_stop_line?(car) || car[:stop_go_token] == crossroad
        end
        next if waiting_group.empty?

        owner = waiting_group.find { |car| car[:stop_go_token] == crossroad }
        owner ||= select_all_way_stop_owner(state.roads, crossroad, waiting_group)

        waiting_group.each do |car|
          if owner&.equal?(car)
            car[:stop_go_token] = crossroad
          else
            car[:stop_go_token] = nil if car[:stop_go_token] == crossroad
            denied << car if at_or_past_stop_line?(car)
          end
        end
      end

    denied
  end

  def resolve_step_crossings(cars, occupancy)
    intents = cars.filter_map { |car| step_intent(car) }
    resolve_gate_crossings(intents, occupancy)
  end

  def resolve_gate_crossings(intents, occupancy)
    denied = []

    intents.group_by { |intent| intent[:target_slot] }.each do |target_slot, group|
      if target_slot_occupied_by_other?(target_slot, occupancy, group)
        group.each { |intent| denied << intent[:car] }
        next
      end

      next if group.size <= 1

      losers = rank_by_right_hand_yield(group).drop(1)
      losers.each { |intent| denied << intent[:car] }
    end

    denied
  end

  def target_slot_occupied_by_other?(target_slot, occupancy, group)
    occupant = occupancy[target_slot]
    return false unless occupant

    group.none? { |intent| intent[:car].equal?(occupant) }
  end

  def midpoint_intent(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    speed = movement_speed(car)
    return nil unless from && to
    return nil unless car[:progress] < CROSSOVER_THRESHOLD
    return nil unless car[:progress] + speed >= CROSSOVER_THRESHOLD

    {
      car: car,
      target_slot: [from[0], from[1], to[0], to[1], :second],
      from_tile: from,
      to_tile: to
    }
  end

  def step_intent(car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    speed = movement_speed(car)
    return nil unless from && to && next_to
    return nil unless car[:progress] >= CROSSOVER_THRESHOLD
    return nil unless car[:progress] + speed >= 1.0

    {
      car: car,
      target_slot: [to[0], to[1], next_to[0], next_to[1], :first],
      from_tile: to,
      to_tile: next_to,
      approach_from: from
    }
  end

  def rank_by_right_hand_yield(group)
    group.sort_by do |intent|
      yielders = group.count do |other|
        !other.equal?(intent) && approaching_from_right?(intent, other)
      end
      from_col, from_row = yield_origin_tile(intent)
      [yielders, tile_order(from_col, from_row)]
    end
  end

  def approaching_from_right?(intent, other)
    my_dx, my_dy = intent_step_vector(intent)
    other_dx, other_dy = intent_step_vector(other)
    # Screen-space cross product: negative means `other` is 90° clockwise
    # (to the right) of `intent`, matching the same right-perpendicular
    # convention used by right_hand_lane_offset.
    (my_dx * other_dy) - (my_dy * other_dx) < 0
  end

  def intent_step_vector(intent)
    from_tile = intent[:approach_from] || intent[:from_tile]
    to_tile = intent[:approach_from] ? intent[:from_tile] : intent[:to_tile]

    projected_step_vector(
      to_tile[0] - from_tile[0],
      to_tile[1] - from_tile[1]
    )
  end

  def yield_origin_tile(intent)
    intent[:approach_from] || intent[:from_tile]
  end

  def try_mid_leg_repath(state, car)
    path = car[:leg][:path]
    current = path[car[:step_index]]
    goal = path[-1]
    return false unless current && goal

    new_path = @pathfinder.find_path(state.roads, current, goal)
    return false unless new_path
    return false if new_path.size < 2
    return false if new_path == path[car[:step_index]..]

    car[:leg] = { path: new_path, direction: car[:leg][:direction] }
    car[:step_index] = 0
    car[:progress] = 0.0
    clear_stop_control_state(car)
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
    car[:stall_ticks] = 0
    clear_stop_control_state(car)
    true
  end

  def spawn_new_car(roads, endpoints, key, slot_occupancy)
    path = best_road_path(roads, endpoints[0], endpoints[1])
    return nil unless path
    return nil if path.size < 2

    spawn_slot = [path[0][0], path[0][1], path[1][0], path[1][1], :first]
    return nil if slot_occupancy[spawn_slot]

    {
      pair_key: key,
      endpoints: endpoints,
      leg: { path: path, direction: 0 },
      step_index: 0,
      progress: 0.0,
      speed: DEFAULT_SPEED,
      current_speed: DEFAULT_SPEED,
      pending_repath: false,
      stall_ticks: 0,
      stop_crossroad: nil,
      stop_arrival_frame: nil,
      stop_go_token: nil
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

  def prepare_car_for_tick(state, car)
    car[:current_speed] ||= car[:speed] || DEFAULT_SPEED
    stop_crossroad = active_stop_controlled_crossroad_for(state.roads, car)

    unless stop_crossroad
      clear_stop_control_state(car)
      car[:current_speed] = accelerate_toward_cruise(car)
      return
    end

    if car[:stop_crossroad] != stop_crossroad
      clear_stop_control_state(car)
      car[:stop_crossroad] = stop_crossroad
    end

    if car[:stop_go_token] == stop_crossroad
      car[:current_speed] = accelerate_toward_cruise(car)
      return
    end

    if at_or_past_stop_line?(car)
      car[:progress] = ALL_WAY_STOP_LINE_PROGRESS
      car[:current_speed] = 0.0
      car[:stop_arrival_frame] ||= state.frame_index
      return
    end

    if should_brake_for_stop_line?(car)
      car[:current_speed] = [movement_speed(car) - STOP_BRAKE_PER_TICK, 0.0].max
    else
      car[:current_speed] = accelerate_toward_cruise(car)
    end
  end

  def select_all_way_stop_owner(roads, crossroad, waiting_group)
    stopped_cars = waiting_group.select { |car| fully_stopped_at_crossroad?(car, crossroad) }
    return nil if stopped_cars.empty?

    earliest_arrival = stopped_cars.map { |car| car[:stop_arrival_frame] }.min
    contenders = stopped_cars.select { |car| car[:stop_arrival_frame] == earliest_arrival }
    intents = contenders.map { |car| all_way_stop_intent(roads, car) }.compact
    return nil if intents.empty?

    rank_by_right_hand_yield(intents).first[:car]
  end

  def all_way_stop_intent(roads, car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    return nil unless from && to && next_to
    return nil unless road_kind_at(roads, to[0], to[1]) == :cross

    {
      car: car,
      from_tile: to,
      to_tile: next_to,
      approach_from: from
    }
  end

  def fully_stopped_at_crossroad?(car, crossroad)
    car[:stop_crossroad] == crossroad &&
      car[:stop_arrival_frame] &&
      at_or_past_stop_line?(car) &&
      movement_speed(car).zero?
  end

  def waits_at_stop_line_without_go_token?(car, stop_crossroad)
    stop_crossroad &&
      car[:stop_crossroad] == stop_crossroad &&
      car[:stop_go_token] != stop_crossroad &&
      at_or_past_stop_line?(car)
  end

  def at_or_past_stop_line?(car)
    car[:progress] >= ALL_WAY_STOP_LINE_PROGRESS - CROSSOVER_EPSILON
  end

  def should_brake_for_stop_line?(car)
    remaining_distance = ALL_WAY_STOP_LINE_PROGRESS - car[:progress]
    return false unless remaining_distance.positive?

    speed = movement_speed(car)
    return false unless speed.positive?

    stopping_distance = (speed * speed) / (2.0 * STOP_BRAKE_PER_TICK)
    remaining_distance <= stopping_distance + speed
  end

  def accelerate_toward_cruise(car)
    cruise_speed = car[:speed] || DEFAULT_SPEED
    current_speed = movement_speed(car)

    if current_speed < cruise_speed
      [current_speed + STOP_ACCEL_PER_TICK, cruise_speed].min
    elsif current_speed > cruise_speed
      [current_speed - STOP_BRAKE_PER_TICK, cruise_speed].max
    else
      cruise_speed
    end
  end

  def movement_speed(car)
    car[:current_speed] || car[:speed] || DEFAULT_SPEED
  end

  def clear_stop_control_state(car)
    car[:stop_crossroad] = nil
    car[:stop_arrival_frame] = nil
    car[:stop_go_token] = nil
  end

  def active_stop_controlled_crossroad_for(roads, car)
    stop_controlled_crossroad_for(roads, car) || exiting_owned_crossroad?(car)
  end

  def stop_controlled_crossroad_for(roads, car)
    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    next_to = path[idx + 2]
    return nil unless from && to && next_to
    return nil unless road_kind_at(roads, to[0], to[1]) == :cross

    to
  end

  def exiting_owned_crossroad?(car)
    owned_crossroad = car[:stop_go_token]
    return nil unless owned_crossroad

    path = car[:leg][:path]
    idx = car[:step_index]
    from = path[idx]
    to = path[idx + 1]
    return nil unless from && to
    return nil unless from == owned_crossroad
    return nil unless car[:progress] < CROSSOVER_THRESHOLD

    owned_crossroad
  end

  def road_kind_at(roads, col, row)
    roads[GridCoordinates.tile_key(col, row)]
  end

  def interpolated_screen_position(camera, from, to, progress)
    from_sx, from_sy = camera.world_to_screen(from[0], from[1], TILE_W, FOOTPRINT_H, ORIGIN_X, ORIGIN_Y)
    to_sx, to_sy = camera.world_to_screen(to[0], to[1], TILE_W, FOOTPRINT_H, ORIGIN_X, ORIGIN_Y)

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
